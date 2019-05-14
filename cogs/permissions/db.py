import enum
import typing

import asyncpg
import discord
from discord.ext import commands
import inflect
inflect = inflect.engine()

from utils import errors

class Permissions(enum.Flag):
	# this class is the single source of truth for the permissions values
	# so DO NOT change any of them, and make sure that new ones exceed the current maximum value!
	none	= 0
	view	= 1
	rename	= 2
	edit	= 4
	create	= 8
	delete	= 16
	manage_permissions = 32
	default = create | view | rename | edit

	def __iter__(self):
		for perm in type(self).__members__.values():
			if perm is not self.default and perm is not self.none and perm in self:
				yield perm

	@classmethod
	async def convert(cls, ctx, arg):
		try:
			return cls.__members__[arg.lower().replace('-', '_')]
		except KeyError:
			valid_perms = inflect.join(list(cls.__members__), conj='or')
			raise commands.BadArgument(f'Invalid permission specified. Try one of these: {valid_perms}.')

# Permissions.__new__ is replaced after class definition
# so to replace that definition, we must also do so after class definition, not during
def __new__(cls, value=None):
	if value is None:
		return cls.none
	return enum.Flag.__new__(cls, value)

Permissions.__new__ = __new__
del __new__

class PermissionsDatabase(commands.Cog):
	def __init__(self, bot):
		self.bot = bot

	async def permissions_for(self, member: discord.Member, title):
		roles = [role.id for role in member.roles] + [member.id]
		perms = await self.bot.pool.fetchval("""
			WITH page_id AS (SELECT page_id FROM pages WHERE guild = $1 AND lower(title) = lower($2))
			SELECT (coalesce(bit_or(permissions), $4) | coalesce(bit_or(allow), 0)) & ~coalesce(bit_or(deny), 0)
			FROM role_permissions FULL OUTER JOIN page_permissions ON (role = entity)
			WHERE
				entity = ANY ($3)
				OR role = ANY ($3)
				AND page_id = (SELECT * FROM page_id)
				OR page_id IS NULL  -- in case there's no page permissions for some role
		""", member.guild.id, title, roles, Permissions.default.value)
		if perms is None:
			return Permissions.default
		return Permissions(perms)

	async def member_permissions(self, member: discord.Member):
		roles = [role.id for role in member.roles]
		perms = await self.bot.pool.fetchval("""
			SELECT bit_or(permissions)
			FROM role_permissions
			WHERE role = ANY ($1)
		""", roles)
		if perms is None:
			return Permissions.default
		return Permissions(perms)

	async def highest_manage_permissions_role(self, member: discord.Member) -> typing.Optional[discord.Role]:
		"""return the highest role that this member has that allows them to edit permissions"""
		member_roles = [role.id for role in member.roles]
		manager_roles = [
			member.guild.get_role(row[0])
			for row in await self.bot.pool.fetch("""
				SELECT role
				FROM role_permissions
				WHERE role = ANY ($1) AND role & $2 != 0
			""", member_roles, Permissions.manage_permissions.value)]
		manager_roles.sort()
		return manager_roles[-1] if manager_roles else None

	async def get_role_permissions(self, role_id):
		return Permissions(await self.bot.pool.fetchval("""
			SELECT permissions
			FROM role_permissions
			WHERE role = $1
		""", role_id))

	async def set_role_permissions(self, role_id, perms: Permissions):
		await self.bot.pool.execute("""
			INSERT INTO role_permissions(role, permissions)
			VALUES ($1, $2)
			ON CONFLICT (role) DO UPDATE SET
				permissions = EXCLUDED.permissions
		""", role_id, perms.value)

	# no unset_role_permissions because unset means to give the default permissions
	# to deny all perms just use deny_role_permissions

	async def allow_role_permissions(self, role_id, new_perms: Permissions):
		return Permissions(await self.bot.pool.fetchval("""
			INSERT INTO role_permissions(role, permissions)
			VALUES ($1, $3)
			ON CONFLICT (role) DO UPDATE SET
				permissions = role_permissions.permissions | $2
			RETURNING permissions
		""", role_id, new_perms.value, (new_perms | Permissions.default).value))

	async def deny_role_permissions(self, role_id, perms):
		"""revoke a set of permissions from a role"""
		return Permissions(await self.bot.pool.fetchval("""
			UPDATE role_permissions
			SET permissions = role_permissions.permissions & ~$2::INTEGER
			WHERE role = $1
			RETURNING permissions
		""", role_id, perms.value))

	async def get_page_overwrites(self, guild_id, title) -> typing.List[typing.Tuple[Permissions, Permissions]]:
		"""get the allowed and denied permissions for a particular page"""
		# TODO figure out a way to raise an error on page not found instead of returning []
		return [tuple(map(Permissions, row)) for row in await self.bot.pool.fetch("""
			WITH page_id AS (SELECT page_id FROM pages WHERE guild = $1 AND lower(title) = lower($2))
			SELECT allow, deny
			FROM page_permissions
			WHERE page_id = (SELECT * FROM page_id)
		""", guild_id, title)]

	async def set_page_overwrites(
		self,
		*,
		guild_id,
		title,
		entity_id,
		allow_perms: Permissions = Permissions.none,
		deny_perms: Permissions = Permissions.none
	):
		"""set the allowed, denied, or both permissions for a particular page and entity (role or member)"""
		if new_allow_perms & new_deny_perms != Permissions.none:
			# don't allow someone to both deny and allow a permission
			raise ValueError('allowed and denied permissions must not intersect')

		try:
			await self.bot.pool.execute("""
				WITH page_id AS (SELECT page_id FROM pages WHERE guild = $1 AND lower(title) = lower($2))
				INSERT INTO page_permissions (page_id, entity, allow, deny)
				VALUES ((SELECT * FROM page_id), $3, $4, $5)
				ON CONFLICT (page_id, entity) DO UPDATE SET
					allow = EXCLUDED.allow,
					deny = EXCLUDED.deny
			""", guild_id, title, entity_id, allow_perms.value, deny_perms.value)
		except asyncpg.NotNullViolationError:
			# the page_id CTE returned no rows
			raise errors.PageNotFoundError(title)

	async def unset_page_overwrites(self, *, guild_id, title, entity_id):
		"""remove all of the allowed and denied overwrites for a page"""
		command_tag = await self.bot.pool.execute("""
			WITH page_id AS (SELECT page_id FROM pages WHERE guild = $1 AND lower(title) = lower($2))
			DELETE FROM page_permissions
			WHERE
				page_id = (SELECT * FROM page_id)
				AND entity = $3
		""", guild_id, title, entity_id)
		count = int(command_tag.split()[-1])
		if not count:
			raise errors.PageNotFoundError(title)

	async def add_page_permissions(
		self,
		*,
		guild_id,
		title,
		entity_id,
		new_allow_perms: Permissions = Permissions.none,
		new_deny_perms: Permissions = Permissions.none
	):
		"""add permissions to the set of "allow" overwrites for a page"""
		if new_allow_perms & new_deny_perms != Permissions.none:
			# don't allow someone to both deny and allow a permission
			raise ValueError('allowed and denied permissions must not intersect')

		try:
			return tuple(map(Permissions, await self.bot.pool.fetchrow("""
				WITH page_id AS (SELECT page_id FROM pages WHERE guild = $1 AND lower(title) = lower($2))
				INSERT INTO page_permissions (page_id, entity, allow, deny)
				VALUES ((SELECT * FROM page_id), $3, $4, $5)
				ON CONFLICT (page_id, entity) DO UPDATE SET
					allow = (page_permissions.allow | EXCLUDED.allow) & ~EXCLUDED.deny,
					deny = (page_permissions.deny | EXCLUDED.deny) & ~EXCLUDED.allow
				RETURNING allow, deny
			""", guild_id, title, entity_id, new_allow_perms.value, new_deny_perms.value)))
		except asyncpg.NotNullViolationError:
			# the page_id CTE returned no rows
			raise errors.PageNotFoundError(title)

	async def unset_page_permissions(self, *, guild_id, title, entity_id, perms):
		"""remove a permission from either the allow or deny overwrites for a page

		This is equivalent to the "grey check" in Discord's UI.
		"""
		return tuple(map(Permissions, await self.bot.pool.fetchrow("""
			WITH page_id AS (SELECT page_id FROM pages WHERE guild = $1 AND lower(title) = lower($2))
			UPDATE page_permissions SET
				allow = allow & ~$4::INTEGER,
				deny = deny & ~$4::INTEGER
			WHERE page_id = (SELECT * FROM page_id) AND entity = $3
			RETURNING allow, deny
		""", guild_id, title, entity_id, perms.value) or (None, None)))

def setup(bot):
	bot.add_cog(PermissionsDatabase(bot))