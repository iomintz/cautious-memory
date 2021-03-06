-- Copyright © 2019 lambda#0987
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

-- :macro list_apps()
-- params: user_id
SELECT app_id, app_name
FROM api_tokens
WHERE user_id = $1
-- :endmacro

-- :macro existing_token()
-- params: user_id, app_id
SELECT app_name, secret
FROM api_tokens
WHERE user_id = $1 AND app_id = $2
-- :endmacro

-- :macro new_token()
-- params: user_id, app_name, secret
INSERT INTO api_tokens (user_id, app_name, secret)
VALUES ($1, $2, $3)
RETURNING app_id
-- :endmacro

-- :macro get_secret()
-- params: user_id, app_id
SELECT secret
FROM api_tokens
WHERE user_id = $1 AND app_id = $2
-- :endmacro

-- :macro delete_user_account()
-- params: user_id
DELETE FROM api_tokens
WHERE user_id = $1
-- :endmacro

-- :macro delete_app()
-- params: user_id, app_id
DELETE FROM api_tokens
WHERE user_id = $1 AND app_id = $2
-- :endmacro
