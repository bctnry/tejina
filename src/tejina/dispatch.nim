import std/strtabs
from std/strutils import startsWith, find
import std/asyncdispatch
import std/asynchttpserver
import std/options
import std/macros
import std/tables

# Request jump utilities.

template temporarilyHandleWith*(req: Request, target: string) =
  ## HTTP 307 redirection helper.
  ## The difference between this and other temporary redirection is that a properly
  ## implemented client would guarantee the endpoint at that location would handle
  ## the exact same request - same path, same method, same anything.
  await req.respond(Http307, "", {"Content-Length": "0", "Location": target}.newHttpHeaders())
  
template permanentlyHandleWith*(req: Request, target: string) =
  ## HTTP 308 redirection helper.
  ## The difference between this and other permanent redirection is that a properly
  ## implemented client would guarantee the endpoint at that location would handle
  ## the exact same request - same path, same method, same anything.
  await req.respond(Http308, "", {"Content-Length": "0", "Location": target}.newHttpHeaders())

template permanentlyJumpTo*(req: Request, target: string) =
  ## HTTP 301 redirection helper.
  ## The difference between this and `permanentlyHandleWith` is that the target
  ## route might not receive the same request (e.g. some client would issue a `GET`
  ## instead of repeating the same `POST` request if an HTTP 301 is received), which
  ## may not be what you're looking for.
  await req.respond(Http301, "", {"Content-Length": "0", "Location": target}.newHttpHeaders())

template foundAt*(req: Request, target: string) =
  ## HTTP 302 redirection helper.
  ## I actually don't know what could justify the differentiation between HTTP 302
  ## and HTTP 303. I would expect one to use this when handling queries and use
  ## `seeOther` when handling `PUT` requests.
  await req.respond(Http302, "", {"Content-Length": "0", "Location": target}.newHttpHeaders())
  
template seeOther*(req: Request, target: string) =
  ## HTTP 303 redirection helper.
  ## The difference between `seeOther` and `foundAt` is that HTTP 303 guarantees that
  ## a proper client would be issuing a `GET`.
  await req.respond(Http303, "", {"Content-Length": "0", "Location": target}.newHttpHeaders())
  
type
  Route* = distinct seq[(bool, string)]
  RouteMatchResult* = distinct StringTableRef

proc parseRoute*(x: string): Route =
  var res: seq[(bool, string)] = @[]
  var i = 0
  let lenx = x.len
  var currentPiece: string = ""
  var inPiece: bool = false
  while i < lenx:
    if inPiece:
      case x[i]:
        of '}':
          res.add((true, currentPiece))
          currentPiece = ""
          inPiece = false
        of '@':
          if i+1 >= lenx: currentPiece.add('@')
          else:
            currentPiece.add(x[i+1])
            i += 1
        else:
          currentPiece.add(x[i])
      i += 1
    else:
      case x[i]:
        of '{':
          if currentPiece.len > 0: res.add((false, currentPiece))
          currentPiece = ""
          inPiece = true
        else:
          currentPiece.add(x[i])
      i += 1
  if currentPiece.len > 0:
    if not inPiece: res.add((false, currentPiece))
    else: res.add((false, "{" & currentPiece))
  return res.Route

proc matchRoute*(r: openArray[(bool, string)], x: string): RouteMatchResult =
  ## `x` requires to be the "path" part of the URL of an HTTP request, i.e.
  ## without the part that starts with the question mark `?`.
  ## This procedure performs *greedy* matching, i.e. when two variables are
  ## right next to each other, the first one will always get all the values,
  ## e.g. with the route `/hello/{username}{userid}/edit` `userid` will
  ## always be empty string.
  var res = newStringTable()
  var i = 0
  let lenx = x.len
  let lenr = r.len
  var stri = 0
  while i < lenr:
    let k = r[i]
    if not k[0]:
      let lenk = k[1].len
      var ki = 0
      while stri + ki < lenx and ki < lenk and x[stri+ki] == k[1][ki]: ki += 1
      if ki < lenk: return nil.RouteMatchResult
      stri = stri + ki
      i += 1
    else:
      var si = stri
      while si < lenx and x[si] != '/': si += 1
      if i+1 < lenr and not r[i+1][0]:
        var pi = 0
        while pi < r[i+1][1].len and r[i+1][1][pi] != '/': pi += 1
        let p = r[i+1][1].substr(0, pi)
        let zi = x.find(p, start=stri, last=si)
        if zi == -1: return nil.RouteMatchResult
        res[r[i][1]] = x.substr(stri, zi-1)
        stri = zi
        i += 1
      else:
        res[r[i][1]] = x.substr(stri, si-1)
        stri = si
        i += 1
  if stri < lenx: return nil.RouteMatchResult
  return res.RouteMatchResult
proc matchRoute*(rx: Route, x: string): RouteMatchResult =
  return ((seq[(bool, string)])(rx)).matchRoute(x)

proc isMatchResultFailure*(x: RouteMatchResult): bool =
  return x.StringTableRef == nil

proc getArg*(x: RouteMatchResult, k: string): string =
  return (x.StringTableRef)[k]

proc `$`*(x: RouteMatchResult): string =
  if x.StringTableRef == nil: return "Fail"
  else: return "Success(" & $(x.StringTableRef) & ")"
        
proc `$`*(x: Route): string =
  let r = seq[(bool, string)](x)
  return $r

proc `[]`*(x: RouteMatchResult, k: string): string =
  return (x.StringTableRef)[k]

template dispatch*(x: static[string], req: untyped, body: untyped) =
  block xx:
    let args = x.parseRoute.matchRoute(req.url.path)
    if ((StringTableRef)(args)) == nil: break xx
    body
    
template dispatch*(x: static[string], args: untyped, req: untyped, body: untyped) =
  block xx:
    let args = x.parseRoute.matchRoute(req.url.path)
    if ((StringTableRef)(args)) == nil: break xx
    body
    
template dispatch*(x: untyped, req: untyped, body: untyped) =
  block xx:
    let args = x.matchRoute(req.url.path)
    if ((StringTableRef)(args)) == nil: break xx
    body
    
template dispatch*(x: untyped, args: untyped, req: untyped, body: untyped) =
  block xx:
    let args = x.matchRoute(req.url.path)
    if ((StringTableRef)(args)) == nil: break xx
    body
    
var allRoute {.compileTime.}: TableRef[string, TableRef[HttpMethod, NimNode]] = newTable[string, TableRef[HttpMethod, NimNode]]()

macro GET*(routeDecl: static[string], body: untyped): untyped =
  if not allRoute.hasKey(routeDecl): allRoute[routeDecl] = newTable[HttpMethod, NimNode]()
  if not allRoute[routeDecl].hasKey(HttpGet): allRoute[routeDecl][HttpGet] = body
  else:
    let new = body.lineInfoObj
    let old = allRoute[routeDecl][HttpGet].lineInfoObj
    raise newException(ValueError, "GET " & routeDecl & " is defined again at" & new.filename & "(" & $new.line & "," & $new.column & ") after its previous definition at " & old.filename & "(" & $old.line & "," & $old.column & ")")

macro POST*(routeDecl: static[string], body: untyped): untyped =
  if not allRoute.hasKey(routeDecl): allRoute[routeDecl] = newTable[HttpMethod, NimNode]()
  if not allRoute[routeDecl].hasKey(HttpPost): allRoute[routeDecl][HttpPost] = body
  else:
    let new = body.lineInfoObj
    let old = allRoute[routeDecl][HttpPost].lineInfoObj
    raise newException(ValueError, "POST " & routeDecl & " is defined again at" & new.filename & "(" & $new.line & "," & $new.column & ") after its previous definition at " & old.filename & "(" & $old.line & "," & $old.column & ")")

macro PUT*(routeDecl: static[string], body: untyped): untyped =
  if not allRoute.hasKey(routeDecl): allRoute[routeDecl] = newTable[HttpMethod, NimNode]()
  if not allRoute[routeDecl].hasKey(HttpPut): allRoute[routeDecl][HttpPut] = body
  else:
    let new = body.lineInfoObj
    let old = allRoute[routeDecl][HttpPut].lineInfoObj
    raise newException(ValueError, "PUT " & routeDecl & " is defined again at" & new.filename & "(" & $new.line & "," & $new.column & ") after its previous definition at " & old.filename & "(" & $old.line & "," & $old.column & ")")

macro HEAD*(routeDecl: static[string], body: untyped): untyped =
  if not allRoute.hasKey(routeDecl): allRoute[routeDecl] = newTable[HttpMethod, NimNode]()
  if not allRoute[routeDecl].hasKey(HttpHead): allRoute[routeDecl][HttpHead] = body
  else:
    let new = body.lineInfoObj
    let old = allRoute[routeDecl][HttpHead].lineInfoObj
    raise newException(ValueError, "HEAD " & routeDecl & " is defined again at" & new.filename & "(" & $new.line & "," & $new.column & ") after its previous definition at " & old.filename & "(" & $old.line & "," & $old.column & ")")

macro DELETE*(routeDecl: static[string], body: untyped): untyped =
  if not allRoute.hasKey(routeDecl): allRoute[routeDecl] = newTable[HttpMethod, NimNode]()
  if not allRoute[routeDecl].hasKey(HttpDelete): allRoute[routeDecl][HttpDelete] = body
  else:
    let new = body.lineInfoObj
    let old = allRoute[routeDecl][HttpDelete].lineInfoObj
    raise newException(ValueError, "DELETE " & routeDecl & " is defined again at" & new.filename & "(" & $new.line & "," & $new.column & ") after its previous definition at " & old.filename & "(" & $old.line & "," & $old.column & ")")

macro TRACE*(routeDecl: static[string], body: untyped): untyped =
  if not allRoute.hasKey(routeDecl): allRoute[routeDecl] = newTable[HttpMethod, NimNode]()
  if not allRoute[routeDecl].hasKey(HttpTrace): allRoute[routeDecl][HttpTrace] = body
  else:
    let new = body.lineInfoObj
    let old = allRoute[routeDecl][HttpTrace].lineInfoObj
    raise newException(ValueError, "TRACE " & routeDecl & " is defined again at" & new.filename & "(" & $new.line & "," & $new.column & ") after its previous definition at " & old.filename & "(" & $old.line & "," & $old.column & ")")

macro OPTIONS*(routeDecl: static[string], body: untyped): untyped =
  if not allRoute.hasKey(routeDecl): allRoute[routeDecl] = newTable[HttpMethod, NimNode]()
  if not allRoute[routeDecl].hasKey(HttpOptions): allRoute[routeDecl][HttpOptions] = body
  else:
    let new = body.lineInfoObj
    let old = allRoute[routeDecl][HttpOptions].lineInfoObj
    raise newException(ValueError, "GET " & routeDecl & " is defined again at" & new.filename & "(" & $new.line & "," & $new.column & ") after its previous definition at " & old.filename & "(" & $old.line & "," & $old.column & ")")

macro CONNECT*(routeDecl: static[string], body: untyped): untyped =
  if not allRoute.hasKey(routeDecl): allRoute[routeDecl] = newTable[HttpMethod, NimNode]()
  if not allRoute[routeDecl].hasKey(HttpConnect): allRoute[routeDecl][HttpConnect] = body
  else:
    let new = body.lineInfoObj
    let old = allRoute[routeDecl][HttpConnect].lineInfoObj
    raise newException(ValueError, "GET " & routeDecl & " is defined again at" & new.filename & "(" & $new.line & "," & $new.column & ") after its previous definition at " & old.filename & "(" & $old.line & "," & $old.column & ")")

macro PATCH*(routeDecl: static[string], body: untyped): untyped =
  if not allRoute.hasKey(routeDecl): allRoute[routeDecl] = newTable[HttpMethod, NimNode]()
  if not allRoute[routeDecl].hasKey(HttpPatch): allRoute[routeDecl][HttpPatch] = body
  else:
    let new = body.lineInfoObj
    let old = allRoute[routeDecl][HttpPatch].lineInfoObj
    raise newException(ValueError, "GET " & routeDecl & " is defined again at" & new.filename & "(" & $new.line & "," & $new.column & ") after its previous definition at " & old.filename & "(" & $old.line & "," & $old.column & ")")


var fallbackRoute {.compileTime.}: TableRef[string, NimNode] = newTable[string, NimNode]()

macro FALLBACK*(routeDecl: static[string], body: untyped): untyped =
  ## `FALLBACK` matches remaining HTTP methods on the route `routeDecl` ("remaining", i.e.
  ## not declared using other Tejina macros like `GET` and `POST`). For routes that does
  ## not have a `FALLBACK` declaration, Tejina uses a default handler that will report an
  ## HTTP 501 error; normally this should be enough, but you may be tempted to define your
  ## own handler. Everything - the special variable `args` and stuff - works the same.
  if fallbackRoute.hasKey(routeDecl):
    let filename = body.lineInfoObj.filename
    let line = body.lineInfoObj.line
    let col = body.lineInfoObj.column
    let filename2 = fallbackRoute[routeDecl].lineInfoObj.filename
    let line2 = fallbackRoute[routeDecl].lineInfoObj.line
    let col2 = fallbackRoute[routeDecl].lineInfoObj.column
    raise newException(
      ValueError,
      filename & "(" & $line & "," & $col & "): Fallback route for " & routeDecl.repr & " already defined at " & filename2 & "(" & $line2 & "," & $col2 & ")"
    )
  fallbackRoute[routeDecl] = body
  
template serveStatic*(req: untyped, routePrefix: static[string], staticFilePrefix: static[string]): untyped =
  block xx:
    if not req.url.path.startsWith(routePrefix): break xx
    let mt = newMimetypes()
    var requestedPathNoPrefix = req.url.path.substr(routePrefix.len)
    if requestedPathNoPrefix.len > 0 and requestedPathNoPrefix[0] == '/':
      requestedPathNoPrefix = "." & requestedPathNoPrefix
    let p = (staticFilePrefix.Path / requestedPathNoPrefix.Path).absolutePath
    if not p.fileExists():
      await req.respond(Http404, "", nil)
    else:
      let ext = p.string[p.changeFileExt("").string.len..<p.string.len]
      let mimetype = mt.getMimetype(ext)
      let f = openAsync(p.string, fmRead)
      let fs = await f.readAll()
      f.close()
      await req.respond(Http200, fs,
                        {"Content-Type": mimetype, "Content-Length": $fs.len}.newHttpHeaders())

template serveStaticStreaming*(req: untyped, routePrefix: static[string], staticFilePrefix: static[string], chunkSize: static[int] = 128): untyped =
  ## The difference between `serveStatic` and this function is that `serveStatic`
  ## will first read all the content from the requested file and then send it to
  ## the client (and thus is able to send with a `Content-Length` header field)
  ## but `serveStaticStreaming` will read from the file and immediately send it
  ## to the client one chunk at a time (and thus is not able to provide a
  ## `Content-Length` header because in an HTTP response the header comes before
  ## the content). This is here in case you need to serve big resource files (e.g.
  ## videos) this way, since I'm afraid that using `readAll` on large files might
  ## lead to big RAM usage. Other than that, there is no difference between the
  ## two macros.
  block xx:
    if not req.url.path.startsWith(routePrefix): break xx
    let mt = newMimetypes()
    var requestedPathNoPrefix = req.url.path.substr(routePrefix.len)
    if requestedPathNoPrefix.len > 0 and requestedPathNoPrefix[0] == '/':
      requestedPathNoPrefix = "." & requestedPathNoPrefix
    let p = (staticFilePrefix.Path / requestedPathNoPrefix.Path).absolutePath
    if not p.fileExists():
      await req.respond(Http404, "", nil)
    else:
      let ext = p.string[p.changeFileExt("").string.len..<p.string.len]
      let mimetype = mt.getMimetype(ext)
      await req.client.send("HTTP/1.1 200\c\L")
      await req.client.send("Content-Type: " & mimetype & "\c\L")
      await req.client.send("Transfer-Encoding: chunked\c\L")
      await req.client.send("\c\L")
      let f = openAsync(p.string, fmRead)
      while true:
        let b = await f.read(chunkSize)
        await req.client.send((b.len).toHex)
        await req.client.send("\c\L")
        await req.client.send(b)
        await req.client.send("\c\L")
        if b.len <= 0: break
      
macro dispatchAllRoute*(reqVarName: untyped): untyped =
  result = nnkStmtList.newTree()
  for k in allRoute.keys():
    let argvar = newIdentNode("args")
    let s = genSym(nskLabel)
    let parsedRoute = k.parseRoute.Route
    var routeBody = nnkStmtList.newTree()
    for kk in allRoute[k].keys():
      let v = newStrLitNode($kk)
      let s = genSym(nskLabel)
      let body = allRoute[k][kk]
      routeBody.add quote do:
        block `s`:
          if $(`reqVarName`.reqMethod) != `v`: break `s`
          `body`
    if not fallbackRoute.hasKey(k):
      routeBody.add quote do:
        await `reqVarName`.respond(Http501, "", nil)
    else:
      routeBody.add(fallbackRoute[k])
    result.add quote do:
      block `s`:
        let `argvar` = `parsedRoute`.matchRoute(`reqVarName`.url.path)
        if ((StringTableRef)(`argvar`)) == nil: break `s`
        `routeBody`


