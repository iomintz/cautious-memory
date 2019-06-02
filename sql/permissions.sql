-- :name permissions_for
-- params: guild_id, title, member_id, role_ids, Permissions.default.value
-- role_ids must include member_id for member specific page overwrites
WITH
	page_id AS (SELECT page_id FROM pages WHERE guild = $1 AND lower(title) = lower($2)),
	everyone_perms AS (SELECT permissions FROM role_permissions WHERE entity = $1)
SELECT
	(
		coalesce(bit_or(permissions), 0)
		| coalesce(bit_or(allow), 0)
		| coalesce((SELECT * FROM everyone_perms), $4))
	& ~coalesce(bit_or(deny), 0)
FROM
	role_permissions
	FULL OUTER JOIN page_permissions USING (entity)
WHERE
	entity = ANY ($3)  -- role permissions / role overwrites
	AND (
		page_id = (SELECT * FROM page_id)
		OR page_id IS NULL)  -- in case there's no page permissions for some role

-- :name member_permissions
-- params: guild_id, role_ids, Permissions.default.value
WITH everyone_perms AS (SELECT permissions FROM role_permissions WHERE entity = $1)
SELECT coalesce(bit_or(permissions), 0) | coalesce((SELECT * FROM everyone_perms),  $3)
FROM role_permissions
WHERE entity = ANY ($2)

-- :name manage_permissions_roles
-- params: role_ids, Permissions.manage_permissions.value
-- role_ids must include guild_id in case the default role has manage permissions
SELECT entity
FROM role_permissions
WHERE entity = ANY ($1) AND permissions & $2 != 0

-- :name get_role_permissions
-- params: role_id
SELECT permissions
FROM role_permissions
WHERE entity = $1

-- :name set_role_permissions
-- params: role_id, perms
INSERT INTO role_permissions(entity, permissions)
VALUES ($1, $2)
ON CONFLICT (entity) DO UPDATE SET
	permissions = EXCLUDED.permissions

-- :name set_default_permissions
-- params: guild_id, Permissions.default.value
INSERT INTO role_permissions(entity, permissions)
VALUES ($1, $2)
ON CONFLICT DO NOTHING

-- :name allow_role_permissions
-- params: role_id, new_perms
INSERT INTO role_permissions(entity, permissions)
VALUES ($1, $2)
ON CONFLICT (entity) DO UPDATE SET
	permissions = role_permissions.permissions | $2
RETURNING permissions

-- :name deny_role_permissions
-- params: role_id, perms
UPDATE role_permissions
SET permissions = role_permissions.permissions & ~$2::INTEGER
WHERE entity = $1
RETURNING permissions

-- :name get_page_overwrites
-- params: guild_id, title
WITH page_id AS (SELECT page_id FROM pages WHERE guild = $1 AND lower(title) = lower($2))
SELECT entity, allow, deny
FROM page_permissions
WHERE page_id = (SELECT * FROM page_id)

-- :name set_page_overwrites
-- params: guild_id, title, entity_id, allowed_perms, denied_perms
WITH page_id AS (SELECT page_id FROM pages WHERE guild = $1 AND lower(title) = lower($2))
INSERT INTO page_permissions (page_id, entity, allow, deny)
VALUES ((SELECT * FROM page_id), $3, $4, $5)
ON CONFLICT (page_id, entity) DO UPDATE SET
	allow = EXCLUDED.allow,
	deny = EXCLUDED.deny

-- :name unset_page_overwrites
-- params: guild_id, title, entity_id
WITH page_id AS (SELECT page_id FROM pages WHERE guild = $1 AND lower(title) = lower($2))
DELETE FROM page_permissions
WHERE
	page_id = (SELECT * FROM page_id)
	AND entity = $3

-- :name add_page_permissions
-- params: guild_id, title, entity_id, new_allow_perms, new_deny_perms
WITH page_id AS (SELECT page_id FROM pages WHERE guild = $1 AND lower(title) = lower($2))
INSERT INTO page_permissions (page_id, entity, allow, deny)
VALUES ((SELECT * FROM page_id), $3, $4, $5)
ON CONFLICT (page_id, entity) DO UPDATE SET
	allow = (page_permissions.allow | EXCLUDED.allow) & ~EXCLUDED.deny,
	deny = (page_permissions.deny | EXCLUDED.deny) & ~EXCLUDED.allow
RETURNING allow, deny

-- :name unset_page_permissions
-- params: guild_id, title, entity_id, perms
WITH page_id AS (SELECT page_id FROM pages WHERE guild = $1 AND lower(title) = lower($2))
UPDATE page_permissions SET
	allow = allow & ~$4::INTEGER,
	deny = deny & ~$4::INTEGER
WHERE page_id = (SELECT * FROM page_id) AND entity = $3
RETURNING allow, deny