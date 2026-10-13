#!/usr/bin/env python3
"""Publish a wikitext file to a MediaWiki page through the API, with a bot password.

usage: wiki-publish.py <api-url> <credentials-file> <page title> <file.mediawiki> [--overwrite]

The credentials file holds one line "User@botname:password" (Special:BotPasswords).
Without --overwrite, an existing page is left untouched.
"""
import http.cookiejar
import json
import sys
import urllib.parse
import urllib.request

api, credfile, title, srcfile = sys.argv[1:5]
overwrite = "--overwrite" in sys.argv[5:]

user, password = open(credfile).read().strip().split(":", 1)
text = open(srcfile, encoding="utf-8").read()

opener = urllib.request.build_opener(
    urllib.request.HTTPCookieProcessor(http.cookiejar.CookieJar()))
opener.addheaders = [("User-Agent", "ds212j-wiki-publish/1.0")]


def call(params, post=False):
    params = dict(params, format="json", formatversion="2")
    data = urllib.parse.urlencode(params).encode()
    if post:
        req = urllib.request.Request(api, data=data)
    else:
        req = urllib.request.Request(api + "?" + data.decode())
    with opener.open(req, timeout=60) as r:
        res = json.load(r)
    if "error" in res:
        sys.exit(f"API error: {res['error'].get('code')}: {res['error'].get('info')}")
    return res


token = call({"action": "query", "meta": "tokens", "type": "login"})["query"]["tokens"]["logintoken"]
login = call({"action": "login", "lgname": user, "lgpassword": password, "lgtoken": token}, post=True)
if login["login"]["result"] != "Success":
    sys.exit(f"login failed: {login['login'].get('reason', login['login']['result'])}")
print(f"logged in as {login['login']['lgusername']}")

page = call({"action": "query", "titles": title})["query"]["pages"][0]
exists = not page.get("missing", False)
if exists and not overwrite:
    sys.exit(f"page '{title}' already exists: not touching it (use --overwrite)")

csrf = call({"action": "query", "meta": "tokens"})["query"]["tokens"]["csrftoken"]
params = {"action": "edit", "title": title, "text": text, "token": csrf,
          "summary": "Debian + mainline kernel on the Synology DS-212j (from the project README)"}
params["nocreate" if exists else "createonly"] = "1"
res = call(params, post=True)["edit"]
print(f"{res['result']}: '{res['title']}' revision {res.get('newrevid')}")
print(api.replace("api.php", "index.php") + "?title=" + urllib.parse.quote(res["title"].replace(" ", "_")))
