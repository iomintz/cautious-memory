-- :name get_page
-- params: guild_id, title
SELECT *
FROM
	pages
	INNER JOIN revisions
		ON pages.latest_revision = revisions.revision_id
WHERE
	guild = $1
	AND lower(title) = lower($2)

-- :name delete_page
-- params: guild_id, title
DELETE FROM pages
WHERE guild = $1 AND lower(title) = $2

-- :name get_page_revisions
-- params: guild_id, title
SELECT
	page_id, revision_id, author, content, revised,
	coalesce_agg(new_title) OVER (PARTITION BY page_id ORDER BY revision_id ASC) AS title
FROM pages INNER JOIN revisions USING (page_id)
WHERE
	guild = $1
	AND lower(title) = lower($2)
ORDER BY revision_id DESC

-- :name get_all_pages
-- params: guild_id
SELECT *
FROM
	pages
	INNER JOIN revisions
		ON pages.latest_revision = revisions.revision_id
WHERE guild = $1
ORDER BY lower(title) ASC

-- :name get_recent_revisions
-- params: guild_id, cutoff
SELECT
	title AS current_title, revision_id, page_id, author, revised,
	coalesce_agg(new_title) OVER (PARTITION BY page_id ORDER BY revision_id ASC) as title
FROM revisions INNER JOIN pages USING (page_id)
WHERE guild = $1 AND revised > $2
ORDER BY revised DESC

-- :name search_pages
-- params: guild_id, query
SELECT *
FROM
	pages INNER JOIN revisions
		ON pages.latest_revision = revisions.revision_id
WHERE
	guild = $1
	AND title % $2
ORDER BY similarity(title, $2) DESC
LIMIT 100

-- :name get_individual_revisions
-- params: guild_id, revision_ids
WITH all_revisions AS (
	-- TODO dedupe from get_page_revisions (use a stored proc?)
	SELECT
		page_id, revision_id, author, content, revised,
		coalesce_agg(new_title) OVER (PARTITION BY page_id ORDER BY revision_id ASC) AS title
	FROM pages INNER JOIN revisions USING (page_id)
	WHERE
		guild = $1
		-- semi-join because the user doesn't specify a title, but we still want to filter by page
		AND EXISTS (
			SELECT 1 FROM revisions r
			WHERE r.page_id = page_id))
-- using an outer query here prevents prematurely filtering the window funcs above to the selected revision IDs
SELECT *
FROM all_revisions
WHERE revision_id = ANY ($2)
ORDER BY revision_id ASC  -- usually this is used for diffs so we want oldest-newest

-- :name create_page
-- params: guild, title
INSERT INTO pages (guild, title)
VALUES ($1, $2)
RETURNING page_id

-- :name get_page_id
-- params: title
SELECT page_id
FROM pages
WHERE
	guild = $1
	AND lower(title) = lower($2)

-- :name rename_page
-- params: guild_id, old_title, new_title
UPDATE pages
SET title = $3
WHERE
	lower(title) = lower($2)
	AND guild = $1
RETURNING page_id

-- :name log_page_rename
-- params: page_id, author_id, new_title
INSERT INTO revisions (page_id, author, new_title)
VALUES ($1, $2, $3)

-- :name create_revision
-- params: page_id, author_id, content
WITH revision AS (
	INSERT INTO revisions (page_id, author, content)
	VALUES ($1, $2, $3)
	RETURNING revision_id)
UPDATE pages
SET latest_revision = (SELECT * FROM revision)
WHERE page_id = $1

-- :name create_first_revision (for creating new pages)
-- params: page_id, author_id, content, title
WITH revision AS (
	INSERT INTO revisions (page_id, author, content, new_title)
	VALUES ($1, $2, $3, $4)
	RETURNING revision_id)
UPDATE pages
SET latest_revision = (SELECT * FROM revision)
WHERE page_id = $1