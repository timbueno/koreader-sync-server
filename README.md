[![AGPL Licence][licence-badge]](COPYING)
Koreader Sync Server
========

Koreader sync server is built on top of the [Gin](http://gin.io) JSON-API
framework which runs on [OpenResty](http://openresty.org/) and is entirely
written in [Lua](http://www.lua.org/).

Users of koreader devices can register their devices to the synchronization
server and use the sync service to keep all reading progress synchronized
between devices.

This project is licenced under Affero GPL v3, see the [COPYING](COPYING) file.

Setup your own server
======================
Using docker, you can spin up your own server in two commands:

```bash
# for quick test
docker run -d -p 7200:7200 --name=kosync koreader/kosync:latest

# for production, we mount redis data volume to persist state
mkdir -p ./logs/{redis,app} ./data/redis
docker run -d -p 7200:7200 \
    -v `pwd`/logs/app:/app/koreader-sync-server/logs \
    -v `pwd`/logs/redis:/var/log/redis \
    -v `pwd`/data/redis:/var/lib/redis \
    --name=kosync koreader/kosync:latest
```

The above command will spin up a sync server in a docker container.

To build your own docker image from scratch:

```bash
docker build --rm=true --tag=koreader/kosync .
```

Alternatively, if you'd rather use docker compose:

```bash
docker compose up -d --build
```

To setup the server manually, please refer to the commands used in
the [Dockerfile][dockerfile].

You can use the following command to verify that the sync server is ready to serve traffic:

```bash
curl -k -v -H "Accept: application/vnd.koreader.v1+json" https://localhost:7200/healthcheck
# should return {"state":"OK"}
```

As you can see, the server responds over HTTPS using a self-signed certificate. If you'd like to run the server behind a reverse proxy and let the proxy handle TLS termination, run the server on port `17200` instead of `7200`. As an example, your Traefik V3 configuration could look like this:

```bash
  kosync:
    # ...
    labels:
      - traefik.enable=true
      - 'traefik.http.routers.kosync.rule=Host(`kosync.example.com`)'
      - 'traefik.http.services.kosync.loadbalancer.server.port=17200'
```

Changing a password
======================

`PUT /users/password` changes an existing account's authentication key. Send the
current username and key in the usual `x-auth-user` and `x-auth-key` headers, and
send the replacement key in the JSON body:

```http
PUT /users/password
Accept: application/vnd.koreader.v1+json
Content-Type: application/json
x-auth-user: <username>
x-auth-key: <current authentication key>

{"password":"<replacement authentication key>"}
```

Like registration, `password` is the client-derived authentication key. KOReader
clients use the MD5 hash of the user's password; the server stores the supplied
value without hashing it again. Both keys must be nonempty strings.

Success returns HTTP 200 with `{"updated":true}`. The username, document progress,
and other account records are unchanged. Clients must use the replacement key
for subsequent requests; update the saved password on all connected readers.
This endpoint requires the current key and does not provide forgotten-password
recovery or create missing accounts.

The current-key check and replacement run atomically in Redis. When competing
requests supply the same old key and different new keys, only one can succeed.
A retry using an old key after a successful change returns HTTP 401, just like an
incorrect key or nonexistent user. If a response is lost, confirm the proposed
replacement with `GET /users/auth` before attempting another change. Supplying the
current key as the replacement is allowed and leaves authentication unchanged.

Invalid replacement values return HTTP 403 (code 2003); Redis failures use the
existing HTTP 502 errors. Use HTTPS when accessing this endpoint. Operators who
manage password changes through a separate trusted API can restrict this route
at their reverse proxy.

Privacy and security
========

Koreader sync server does not store file name or file content in the database.
For each user it uses a unique string of 32 digits (MD5 hash) to identify the
same document from multiple koreader devices and keeps a record of the furthest
reading progress for that document. Sample progress data entries stored in the
sync server are like these:
```
"user:chrox:document:0b229176d4e8db7f6d2b5a4952368d7a:percentage"  --> "0.31879884821061"
"user:chrox:document:0b229176d4e8db7f6d2b5a4952368d7a:progress"    --> "/body/DocFragment[20]/body/p[22]/img.0"
"user:chrox:document:0b229176d4e8db7f6d2b5a4952368d7a:device"      --> "PocketBook"
```
And the account authentication information is stored like this:
```
"user:chrox:key"  --> "1c56000eef209217ec0b50354558ab1a"
```
the password is MD5 hashed at client when authorizing with the sync server.

In addition, all data transferred between koreader devices and the sync server
are secured by HTTPS (Hypertext Transfer Protocol Secure) connections.

[licence-badge]:http://img.shields.io/badge/licence-AGPL-brightgreen.svg
[dockerfile]:https://github.com/koreader/koreader-sync-server/blob/master/Dockerfile

### Deleting an account

`DELETE /users/me` accepts the normal `x-auth-user` / `x-auth-key` headers and
returns `{ "deleted": true }`. The username and key must be nonempty and the
username must not contain a colon. For an existing account the key must match.
Deletion atomically checks authentication and removes all `user:<username>:`
keys, including credentials and reading progress. An absent account returns HTTP
404 with `{ "code": 2006, "message": "Account not found." }`; any orphaned user
keys are removed. A wrong key for an existing account still returns HTTP 401,
code 2001. Callers can treat the explicit account-not-found result as completed
deletion when reconciling a lost response; a generic 404 or 401 is not sufficient.

No request IDs, deletion markers, or credentials are retained by the server.
The username may be registered again immediately, with empty progress. A deletion
retry with the old password cannot delete a re-registered account with a different
password. The server cannot distinguish generations that reuse both the same
username and password. Applications needing this distinction should generate fresh
credentials when creating another account.

Progress updates check authentication at the Redis write so an earlier
successful authorization cannot write after account removal. Registration uses
`SETNX` to avoid overwriting credentials when registrations race. An independent
signup arriving after deletion may create the username again; deletion does not
reserve or permanently block usernames.
