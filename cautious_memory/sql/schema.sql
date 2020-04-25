-- Copyright © 2019–2020 lambda#0987
--
-- Cautious Memory is free software: you can redistribute it and/or modify
-- it under the terms of the GNU Affero General Public License as published
-- by the Free Software Foundation, either version 3 of the License, or
-- (at your option) any later version.
--
-- Cautious Memory is distributed in the hope that it will be useful,
-- but WITHOUT ANY WARRANTY; without even the implied warranty of
-- MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
-- GNU Affero General Public License for more details.
--
-- You should have received a copy of the GNU Affero General Public License
-- along with Cautious Memory.  If not, see <https://www.gnu.org/licenses/>.

SET TIME ZONE UTC;

--- PAGES

-- this length limit must match cogs/wiki/db.py
\set title_length_limit 200

CREATE TABLE pages (
	page_id INTEGER GENERATED BY DEFAULT AS IDENTITY PRIMARY KEY,
	title VARCHAR(:title_length_limit) NOT NULL,
	guild_id BIGINT NOT NULL,
	-- lets us find the text of the page
	-- the default is an invalid revision_id
	latest_revision_id INTEGER NOT NULL DEFAULT 0,
	-- this information could be gotten by just looking at the date of the oldest revision
	-- but this way is easier
	created TIMESTAMP WITHOUT TIME ZONE DEFAULT CURRENT_TIMESTAMP
);

-- this unique constraint is only a best effort attempt,
-- as it doesn't prevent aliases from having the same title
CREATE UNIQUE INDEX pages_uniq_idx ON pages (lower(title), guild_id);
CREATE INDEX pages_title_trgm_idx ON pages USING GIN (title gin_trgm_ops);

CREATE TABLE contents (
	content_id INTEGER GENERATED BY DEFAULT AS IDENTITY PRIMARY KEY,
	content VARCHAR(2000) NOT NULL
);

CREATE TABLE revisions (
	revision_id INTEGER GENERATED BY DEFAULT AS IDENTITY (START WITH 1) PRIMARY KEY,
	page_id INTEGER NOT NULL REFERENCES pages ON DELETE CASCADE,
	author_id BIGINT NOT NULL,
	title VARCHAR(:title_length_limit) NOT NULL,
	content_id INTEGER NOT NULL REFERENCES contents,
	revised TIMESTAMP WITHOUT TIME ZONE DEFAULT CURRENT_TIMESTAMP
);

ALTER TABLE pages
ADD CONSTRAINT pages_latest_revision_id_fkey
FOREIGN KEY (latest_revision_id)
REFERENCES revisions DEFERRABLE INITIALLY DEFERRED;

CREATE TABLE aliases (
	title VARCHAR(:title_length_limit) NOT NULL,
	page_id INTEGER NOT NULL REFERENCES pages ON DELETE CASCADE,
	aliased TIMESTAMP WITHOUT TIME ZONE DEFAULT CURRENT_TIMESTAMP,
	-- denormalized a bit to make the unique constraint possible
	guild_id BIGINT NOT NULL
);

-- see note on the pages unique index
CREATE UNIQUE INDEX aliases_uniq_idx ON aliases (lower(title), guild_id);
CREATE INDEX aliases_name_trgm_idx ON aliases USING GIN (title gin_trgm_ops);

CREATE TABLE page_usage_history(
	page_id INTEGER NOT NULL REFERENCES pages ON DELETE CASCADE,
	time TIMESTAMP WITHOUT TIME ZONE DEFAULT (now() AT TIME ZONE 'UTC')
);

CREATE INDEX page_usage_history_idx ON page_usage_history (page_id);

--- WATCH LISTS / MESSAGE BINDING

CREATE TABLE page_subscribers(
	-- this is NOT a foreign key because we need to notify page subscribers when a page is deleted
	page_id BIGINT NOT NULL,
	user_id BIGINT NOT NULL,
	PRIMARY KEY (page_id, user_id)
);

CREATE INDEX page_subscribers_user_id_idx ON page_subscribers (user_id);

CREATE TABLE bound_messages(
	message_id BIGINT PRIMARY KEY,
	channel_id BIGINT NOT NULL,
	-- this is NOT a foreign key because we need to delete bound messages when a page is deleted
	page_id INTEGER NOT NULL
);

CREATE INDEX bound_messages_page_id_idx ON bound_messages (page_id);

CREATE FUNCTION notify_page_edit() RETURNS TRIGGER AS $$ BEGIN
	PERFORM * FROM pg_notify('page_edit', new.revision_id::text);
	RETURN new;
END; $$ LANGUAGE plpgsql;

CREATE TRIGGER notify_page_edit
AFTER INSERT ON revisions
FOR EACH ROW
EXECUTE PROCEDURE notify_page_edit();

CREATE FUNCTION notify_page_delete() RETURNS TRIGGER AS $$ BEGIN
	PERFORM * FROM pg_notify('page_delete', old.guild_id::text || ',' || old.page_id::text || ',' || old.title);
	RETURN NULL;
END; $$ LANGUAGE plpgsql;

CREATE TRIGGER notify_page_delete
AFTER DELETE ON pages
FOR EACH ROW
EXECUTE PROCEDURE notify_page_delete();

--- PERMISSIONS

CREATE TABLE role_permissions(
	-- these are always roles, but the column is named "entity" to ease joining with page_permissions
	entity BIGINT PRIMARY KEY,
	permissions INTEGER NOT NULL
);

CREATE TABLE page_permissions(
	page_id INTEGER NOT NULL REFERENCES pages ON DELETE CASCADE,
	-- either a role ID or a member ID
	entity BIGINT NOT NULL,
	-- permissions to allow which overwrite role permissions
	allow INTEGER NOT NULL DEFAULT 0,
	-- permissions to deny
	deny INTEGER NOT NULL DEFAULT 0,

	-- you may not allow and deny a permission
	CHECK (allow & deny = 0),
	PRIMARY KEY (page_id, entity)
);

--- API

CREATE TABLE api_tokens(
	user_id BIGINT NOT NULL,
	app_id BIGINT GENERATED BY DEFAULT AS IDENTITY,
	app_name VARCHAR(200),
	secret BYTEA NOT NULL,

	PRIMARY KEY (user_id, app_id)
);
