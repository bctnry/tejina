# Tejina

![Tejina logo](./logo.png)

**手品** (てじな; Tejina): Magic trick; sleight of hand

Minimal web framework for Nim.

Note that this is intended to work with `std/asynchttpserver`.

## Install

Tejina is very small and is originally designed to be directly incorporate into
the codebase. You can directly copy the two files in the `src/tejina` folder to
the location of your choice. You can also download this project and use
`nimble install`.

## Quick start

``` nim
import tejina/[dispatch, templates]

# Things that you're going to need while handling the requests, e.g. database
# connections and configs.
type
  Context* = ref object
    someField*: string 
	
# Define routes here.
GET "/route1":
  # Loads file "mytemplate.html" (path relative to the residing directory of
  # the current source file), evaluates it and stores the result in the
  # variable `results` as a string. For example, `expandTemplate(xyz, "blah")`
  # will stores the result in the variable `xyz`.
  expandTemplate(results, "mytemplate.html")
  await req.respond(Http200, results,
                    {"Content-Type": "text/html;charset=utf-8"}.newHttpHeaders())
					
FALLBACK "/route1":
  # This handles all the other methods on route "/route1" that's not defined.
  # Tejina returns an HTTP 501 error for undefined methods by default, but in case
  # you want to handle this yourself, you can use `FALLBACK`.
  await req.respond(Http404, "", nil)
					
# You can use variables in routes. Variables are surrounded by curly brackets.
GET "/route2/{id}":
  # You can use `args["id"]` to access the matched values.
  # `args` is a `StringTableRef`, defined in `std/strtabs`.
  expandTemplate(results, "mytemplate2.html")
  await req.respond(Http200, results,
                    {"Content-Type": "text/html;charset=utf-8"}.newHttpHeaders())
	
# Then, set up asynchttpserver:
proc serveHTTP*() {.async.} =
  var server = newAsyncHttpServer()
  let context = Context(test: "blah")
  
  # This part is very important.
  # Whatever variables bound in this scope is available in the routes, but
  # `acceptRequest` only accepts a procedure taking only one argument of type
  # `Request`, thus if you want to have other variables you'll have to do
  # this kind of manoeuvre. The variable `args` (used for the variables in
  # the routes), however, is always available, since it's directly inserted
  # with macros.
  proc cb(req: Request) {.async.} =
    # As explained above, all declared routes can use the value of `context`
    # through the id `ctx`.
    await (proc (req: Request, ctx: Context) {.async.} =
             # By doing this, all paths that start with "/static" would be
             # handled by Tejina's static directory handler, which replaces
             # "/static" with "./static-assets". Both of these arguments can
             # be freely customized. But please note that if you choose to
             # have a relative path for the second argument, that relative
             # path would be resolved using the current working directory
             # as the base (so if your CWD is "/var/www/html/some-domain"
             # this would become "/var/www/html/some-domain/static-assets").
             # It's recommended to use an absolute path here if you need
             # to make sure it would truly resolve at the place where you want.
             # This would handle paths like "/static" (resolving to
             # "./static-assets"), "/static/" (resolving to "./static-assets/"),
             # "/static/*" (resolving to "./static-assets/*") but not
             # "/static*" (e.g. "/staticblah").
             req.serveStatic("/static", "./static-assets")
             
             # Use `dispatchAllRoute(req)` to expand all the route definitions
             # so far into statements that do the dispatch for you which you
             # would have to write manually originally.
             dispatchAllRoute(req)
             
             # It's recommended to have this as a "catch-all".
             req.respond(Http404, "", nil))(req, context)

  server.listen(9000.Port)
  echo server.getPort().uint16
  while true:
    if server.shouldAcceptRequest():
      await server.acceptRequest(cb)
    else:
      # too many concurrent connections, `maxFDs` exceeded
      # wait 500ms for FDs to be closed
      await sleepAsync(500)

waitFor serveHTTP()
  
```

## Syntax for routes

+ Everything between curly braces, i.e. `{}`, is considered to be a variable within the route that should take the value of the strings at that position; e.g. `/user/{id}` will match `/user/abc` and `/user/def` and returns the mapping `id => "abc"` and `id => "def"` respectively.
+ Matches are **exact**, meaning that routes defined with `/user/{id}` will not handle requests for `/user/{id}/edit`.
+ The matched values never goes beyond one level; e.g. `/user/{id}` will NOT match `/user/abc/def` with `id => "abc/def"`.
+ To represent a literal curly brace character, use the at-sign character `@` before it (e.g. write `/some-@{url@}` instead of `/some-{url}`. The at-sign itself is escaped with sequence `@@`.
+ You can match "the rest of the path" by postfixing your route with `**` (e.g. `/user/{id}/**` will match paths like `/user/abc/edit` and `/user/abc/edit/confirm`). `**` must be at the end of the route declaration, or else a compile error would be raised. The strings matched by this pattern would be set as `_rest` in the resulting `args` (e.g. matching `/user/abc/edit/confirm` with `/user/{id}/**` would return `id => "abc"; _args => "edit/confirm"`.

## Syntax for templates

Templates are mostly HTML with template tags (surrounded by double-curly-braces, i.e. `{{ ... }}`) insterted within. All template tags are considered to contain valid Nim expressions that will return the string that's meant to be inserted at its position when evaluated other than all the "special tags" listed as follows:

+ `{{include [filename]}}`: This tag causes the macro evaluator reads the file content of `[filename]` and use it as a part of the template. 
+ `{{for [var] in [expr]}}` ... `{{/for}}`: The `for` construct. The content within this construct will be rendered for each of the elements from `[expr]` (which is bound to the variable `[var]`. Currently `[var]` must be a single variable (i.e. things like `for k, n in someExpr` are not allowed)
+ `{{if [cond]}}` ... `{{elif [cond}}` ... `{{else [cond]}}` ... `{{/if}}`: The `if`...`elif`...`else` construct. Only the part within the branch where `[cond]` evaluates to `true` will be rendered and appended to the result.

## How Tejina works

Both the template engine part and the routing part of Tejina are implemented as macros and run at compile time. The template engine converts raw strings read from the template files and generates statements (`for` and `if` tags are converted to `for` and `if` statements in Nim, respectively). The macros used to declare routes (e.g. the `GET` and `POST` you see in the example above) simply collect the following code into a dictionary; this dictionary is converted to the actual dispatching code by calling `dispatchAllRoute`.


