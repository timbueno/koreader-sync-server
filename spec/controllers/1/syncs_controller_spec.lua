require 'spec.spec_helper'


local function clear_db()
    local redis = require("redis")
    local client = redis.connect("127.0.0.1", 6379)
    client:select(2)
    client:flushdb()
end

describe("SyncsController", function()
    before_each(function()
        clear_db()
    end)

    after_each(function()
        clear_db()
    end)

    local function register(username, userkey)
        local response = hit({
            scheme = "https",
            method = "POST",
            path = "/users/create",
            body = { username = username, password = userkey },
        })

        return response
    end

    local function authorize(username, userkey)
        local response = hit({
            scheme = "https",
            method = "GET",
            path = "/users/auth",
            headers = {
                ["x-auth-user"] = username,
                ["x-auth-key"] = userkey,
            },
        })

        return response
    end

    local function delete_user(username, userkey)
        local response = hit({
            scheme = "https",
            method = "DELETE",
            path = "/users/me",
            headers = {
                ["x-auth-user"] = username,
                ["x-auth-key"] = userkey,
            },
        })

        return response
    end

    local function get(username, userkey, document)
        local response = hit({
            scheme = "https",
            method = "GET",
            path = "/syncs/progress/" .. document,
            headers = {
                ["x-auth-user"] = username,
                ["x-auth-key"] = userkey,
            },
        })

        return response
    end

    local function update(username, userkey, document, percentage, progress, device)
        local response = hit({
            scheme = "https",
            method = "PUT",
            path = "/syncs/progress",
            headers = {
                ["x-auth-user"] = username,
                ["x-auth-key"] = userkey,
            },
            body = {
                document = document,
                progress = progress,
                percentage = percentage,
                device = device,
            }
        })

        return response
    end

    describe("#create", function()
        it("adds new user", function()
            local response = register("new-user", "passwd123")
            assert.are.same(201, response.status)
            assert.are.same({ username = "new-user" }, response.body)
        end)
        it("cannot add duplicated user", function()
            local response = register("new-user", "passwd123")
            assert.are.same(201, response.status)
            assert.are.same({ username = "new-user" }, response.body)
            response = register("new-user", "passwd123")
            assert.are.same(402, response.status)
            assert.are.same({
                code = 2002,
                message = "Username is already registered."
            }, response.body)
        end)
    end)

    describe("#auth", function()
        it("should authorize", function()
            local username, userkey = "user1", "passwd123"
            local response = register(username, userkey)
            response = authorize(username, "")
            assert.are.same(401, response.status)
            assert.are.same({code = 2001, message = "Unauthorized"}, response.body)
            response = authorize(username, "wrong_password")
            assert.are.same(401, response.status)
            assert.are.same({code = 2001, message = "Unauthorized"}, response.body)
            response = authorize(username, userkey)
            assert.are.same(200, response.status)
            assert.are.same("OK", response.body.authorized)
        end)
    end)

    describe("#delete", function()
        it("requires valid credentials", function()
            local username, userkey = "user1", "passwd123"
            register(username, userkey)

            local response = delete_user(username, "wrong_password")
            assert.are.same(401, response.status)
            assert.are.same({code = 2001, message = "Unauthorized"}, response.body)
            assert.are.same(200, authorize(username, userkey).status)
        end)

        it("deletes the user and all progress", function()
            local username, userkey = "user1", "passwd123"
            local doc1, doc2 = "document1", "document2"
            register(username, userkey)
            update(username, userkey, doc1, 0.32, "56", "my kpw")
            update(username, userkey, doc2, 0.64, "112", "my kpw")

            local response = delete_user(username, userkey)
            assert.are.same(200, response.status)
            assert.are.same({ deleted = true }, response.body)
            assert.are.same(401, authorize(username, userkey).status)

            -- Re-registering the username should start with no old progress.
            assert.are.same(201, register(username, "new-password").status)
            assert.are.same({}, get(username, "new-password", doc1).body)
            assert.are.same({}, get(username, "new-password", doc2).body)
        end)

        it("does not treat glob characters in usernames as wildcards", function()
            register("user*one", "password-one")
            register("userXone", "password-two")
            update("user*one", "password-one", "document1", 0.32, "56", "device one")
            update("userXone", "password-two", "document2", 0.64, "112", "device two")

            assert.are.same(200, delete_user("user*one", "password-one").status)
            assert.are.same(200, authorize("userXone", "password-two").status)
            assert.are.same("document2",
                get("userXone", "password-two", "document2").body.document)
        end)
    end)

    describe("#deletion retries", function()
        local function client()
            local connection = require("redis").connect("127.0.0.1", 6379)
            connection:select(2)
            return connection
        end

        it("distinguishes repeated and absent accounts without retaining records", function()
            register("reader", "key")
            update("reader", "key", "doc", 0.32, "56", "device")
            assert.are.same(200, delete_user("reader", "key").status)
            local retry = delete_user("reader", "key")
            assert.are.same(404, retry.status)
            assert.are.same({ code = 2006, message = "Account not found." }, retry.body)
            assert.are.same(404, delete_user("missing", "key").status)
            local redis = client()
            assert.are.same({}, redis:keys("*"))
            redis:quit()
        end)

        it("allows username reuse and rejects the old key after re-registration", function()
            register("reader", "old-key")
            delete_user("reader", "old-key")
            assert.are.same(401, update("reader", "old-key", "doc", 0.3, "56", "device").status)
            assert.are.same(201, register("reader", "new-key").status)
            assert.are.same(401, delete_user("reader", "old-key").status)
            assert.are.same(200, authorize("reader", "new-key").status)
            assert.are.same({}, get("reader", "new-key", "doc").body)
            assert.are.same(200, delete_user("reader", "new-key").status)
            assert.are.same(201, register("reader", "new-key").status)
        end)

        it("requires well-formed authentication even when the account is absent", function()
            for _, response in ipairs({ delete_user(nil, "key"), delete_user("", "key"),
                delete_user("reader:other", "key"), delete_user("reader", nil), delete_user("reader", "") }) do
                assert.are.same(401, response.status)
            end
        end)

        it("cleans orphaned progress for an absent account without touching another user", function()
            register("other", "other-key")
            local redis = client()
            redis:hmset("user:missing:document:doc", "progress", "56")
            redis:quit()
            assert.are.same(404, delete_user("missing", "key").status)
            redis = client()
            assert.are.same({}, redis:keys("user:missing:*"))
            redis:quit()
            assert.are.same(200, authorize("other", "other-key").status)
        end)

        it("fails closed on Redis type errors", function()
            local redis = client()
            redis:lpush("user:broken:key", "wrong-type")
            redis:quit()
            assert.are.same(502, delete_user("broken", "key").status)
            redis = client()
            assert.are.same({ "wrong-type" }, redis:lrange("user:broken:key", 0, -1))
            redis:quit()
        end)
    end)

    describe("#sync", function()
        local username, userkey, doc = "user1", "passwd123", "89isjkdaj9j"
        before_each(function()
            register(username, userkey)
        end)
        it("should authorize itself before getting progress", function()
            local response = get(username, userkey.."wrong_pass", doc)
            assert.are.same(401, response.status)
            assert.are.same({code = 2001, message = "Unauthorized"}, response.body)
        end)
        it("should authorize itself before updating progress", function()
            local response = update(username, userkey.."wrong_pass",
                doc, 0.32, "56", "my kpw")
            assert.are.same(401, response.status)
            assert.are.same({code = 2001, message = "Unauthorized"}, response.body)
        end)
        it("should update document progress", function()
            local response = update(username, userkey, doc, 0.32, "56", "my kpw")
            assert.are.same(200, response.status)
            assert.are.same(doc, response.body.document)
            assert.truthy(response.body.timestamp)
        end)
        it("cannot get progress of non-existent document", function()
            update(username, userkey, doc, 0.32, "56", "my kpw")
            local response = get(username, userkey, doc .. "non_existent")
            assert.are.same(200, response.status)
            assert.are.same({}, response.body)
        end)
        it("should get document progress", function()
            update(username, userkey, doc, 0.32, "56", "my kpw")
            local response = get(username, userkey, doc)
            assert.are.same(200, response.status)
            assert.truthy(response.body.timestamp)
            -- Clear timestamp, it varies.
            response.body.timestamp = nil
            assert.are.same({
                document = doc,
                percentage = 0.32,
                progress = "56",
                device = "my kpw"
            }, response.body)
        end)
        it("should get the latest document progress", function()
            update(username, userkey, doc, 0.32, "56", "my kpw")
            -- 36 is writting later, so we should get it.
            update(username, userkey, doc, 0.22, "36", "my pb")
            local response = get(username, userkey, doc)
            assert.are.same(200, response.status)
            assert.truthy(response.body.timestamp)
            -- Clear timestamp, it varies.
            response.body.timestamp = nil
            assert.are.same({
                document = doc,
                percentage = 0.22,
                progress = "36",
                device = "my pb"
            }, response.body)
        end)
    end)
end)
