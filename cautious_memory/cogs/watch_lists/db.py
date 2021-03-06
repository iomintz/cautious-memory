# Copyright © 2019–2020 lambda#0987
#
# Cautious Memory is free software: you can redistribute it and/or modify
# it under the terms of the GNU Affero General Public License as published
# by the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# Cautious Memory is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU Affero General Public License for more details.
#
# You should have received a copy of the GNU Affero General Public License
# along with Cautious Memory.  If not, see <https://www.gnu.org/licenses/>.

import asyncio
import contextlib
import datetime as dt
import logging

import discord
from discord.ext import commands
from bot_bin.sql import connection, optional_connection

from ..permissions.db import Permissions
from ... import utils
from ...utils import AttrDict, errors

logger = logging.getLogger(__name__)

class WatchListsDatabase(commands.Cog):
	NOTIFICATION_EMBED_COLOR = discord.Color.from_hsv(262/360, 55/100, 76/100)

	def __init__(self, bot):
		self.bot = bot
		self.wiki_commands = self.bot.cogs['Wiki']
		self.wiki_db = self.bot.cogs['WikiDatabase']
		self.queries = self.bot.queries('watch_lists.sql')

	@commands.Cog.listener()
	@optional_connection
	async def on_cm_page_edit(self, revision_id):
		async with connection().transaction():
			old, new = await self.get_revision_and_previous(revision_id)
			guild = self.bot.get_guild(new.guild_id)
			if guild is None:
				logger.warning(f'on_cm_page_edit: guild_id {new.guild_id} not found!')
				return

			async def send(user_id):
				# editing a page you subscribe to should not notify yourself
				if user_id == new.author_id:
					return

				try:
					recipient = await utils.fetch_member(guild, user_id)
				except discord.NotFound:
					return

				try:
					await self.wiki_db.check_permissions(recipient, Permissions.view, new.current_title)
				except errors.MissingPagePermissionsError:
					return

				with contextlib.suppress(discord.NotFound):
					new.author = await utils.fetch_member(guild, new.author_id)

				with contextlib.suppress(discord.NotFound):
					old.author = await utils.fetch_member(guild, old.author_id)

				await recipient.send(embed=self.page_edit_notification(recipient, old, new))

			await asyncio.gather(*map(send, await self.page_subscribers(new.page_id)))

	@commands.Cog.listener()
	@optional_connection
	async def on_cm_page_delete(self, guild_id, page_id, title):
		guild = self.bot.get_guild(guild_id)
		if guild is None:
			logger.warning(f'on_cm_page_delete: guild_id {guild_id} not found!')
			return

		async def send(user_id):
			try:
				member = await utils.fetch_member(guild, user_id)
			except discord.NotFound:
				return

			await member.send(embed=self.page_delete_notification(guild, title))

		await asyncio.gather(*map(send, await self.page_subscribers(page_id)))
		await self.delete_page_subscribers(page_id)

	def page_edit_notification(self, recipient, old, new):
		embed = discord.Embed()
		embed.title = f'Page “{new.current_title}” was edited in server {recipient.guild}'
		embed.color = self.NOTIFICATION_EMBED_COLOR
		embed.set_footer(text='Edited')
		embed.timestamp = new.revised
		if new.author is not None:
			embed.set_author(name=new.author.name, icon_url=new.author.avatar_url_as(static_format='png', size=64))
		try:
			embed.description = self.wiki_commands.diff(old, new)
		except commands.UserInputError as exc:
			embed.description = str(exc)
		return embed

	def page_delete_notification(self, guild, title):
		embed = discord.Embed()
		embed.title = f'Page “{title}” was deleted in server {guild}'
		embed.color = self.NOTIFICATION_EMBED_COLOR
		embed.set_footer(text='Deleted')
		embed.timestamp = dt.datetime.utcnow()  # ¯\_(ツ)_/¯
		return embed

	@optional_connection
	async def watch_page(self, member, title) -> bool:
		"""subscribe the given user to the given page.
		return success, ie True if they were not a subscriber before.
		"""
		async with connection().transaction():
			title = (await self.wiki_db.resolve_page(member, title)).target
			tag = await connection().execute(self.queries.watch_page(), member.guild.id, member.id, title)
			if tag.rsplit(None, 1)[-1] == '0':
				raise errors.PageNotFoundError(title)

	@optional_connection
	async def unwatch_page(self, member, title) -> bool:
		"""unsubscribe the given user from the given page.
		return success, ie True if they were a subscriber before.
		"""
		tag = await connection().execute(self.queries.unwatch_page(), member.guild.id, member.id, title)
		return tag.split(None, 1)[-1] == '1'

	@optional_connection
	async def watch_list(self, member):
		async with connection().transaction():
			async for page_id, title in connection().cursor(self.queries.watch_list(), member.guild.id, member.id):
				yield page_id, title

	@optional_connection
	async def page_subscribers(self, page_id):
		return [user_id for user_id, in await connection().fetch(self.queries.page_subscribers(), page_id)]

	@optional_connection
	async def delete_page_subscribers(self, page_id):
		await connection().execute(self.queries.delete_page_subscribers(), page_id)

	@optional_connection
	async def get_revision_and_previous(self, revision_id):
		rows = list(map(AttrDict, await connection().fetch(self.queries.get_revision_and_previous(), revision_id)))
		for row in rows: row.author = None
		if len(rows) == 1: rows.append(None)
		return rows[::-1]  # old to new

def setup(bot):
	bot.add_cog(WatchListsDatabase(bot))
