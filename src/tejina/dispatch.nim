import std/strtabs
from std/strutils import startsWith, find
import std/asyncdispatch
import std/asynchttpserver
import std/options
import std/macros
import std/tables

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

var allRoute {.compileTime.}: TableRef[HttpMethod, TableRef[string, NimNode]] = newTable[HttpMethod, TableRef[string, NimNode]]()

macro GET*(routeDecl: static[string], body: untyped): untyped =
  if not allRoute.hasKey(HttpGet):
    allRoute[HttpGet] = newTable[string, NimNode]()
  allRoute[HttpGet][routeDecl] = body
macro POST*(routeDecl: static[string], body: untyped): untyped =
  if not allRoute.hasKey(HttpPost):
    allRoute[HttpPost] = newTable[string, NimNode]()
  allRoute[HttpPost][routeDecl] = body
macro PUT*(routeDecl: static[string], body: untyped): untyped =
  if not allRoute.hasKey(HttpPost):
    allRoute[HttpPut] = newTable[string, NimNode]()
  allRoute[HttpPut][routeDecl] = body
macro HEAD*(routeDecl: static[string], body: untyped): untyped =
  if not allRoute.hasKey(HttpHead):
    allRoute[HttpHead] = newTable[string, NimNode]()
  allRoute[HttpHead][routeDecl] = body
macro DELETE*(routeDecl: static[string], body: untyped): untyped =
  if not allRoute.hasKey(HttpDelete):
    allRoute[HttpDelete] = newTable[string, NimNode]()
  allRoute[HttpDelete][routeDecl] = body
macro TRACE*(routeDecl: static[string], body: untyped): untyped =
  if not allRoute.hasKey(HttpTrace):
    allRoute[HttpTrace] = newTable[string, NimNode]()
  allRoute[HttpTrace][routeDecl] = body
macro OPTIONS*(routeDecl: static[string], body: untyped): untyped =
  if not allRoute.hasKey(HttpOptions):
    allRoute[HttpOptions] = newTable[string, NimNode]()
  allRoute[HttpOptions][routeDecl] = body
macro CONNECT*(routeDecl: static[string], body: untyped): untyped =
  if not allRoute.hasKey(HttpConnect):
    allRoute[HttpConnect] = newTable[string, NimNode]()
  allRoute[HttpConnect][routeDecl] = body
macro PATCH*(routeDecl: static[string], body: untyped): untyped =
  if not allRoute.hasKey(HttpPatch):
    allRoute[HttpPatch] = newTable[string, NimNode]()
  allRoute[HttpPatch][routeDecl] = body

macro dispatchAllRoute*(reqVarName: untyped): untyped =
  result = nnkStmtList.newTree()
  for k in allRoute.keys():
    let v = newStrLitNode($k)
    var routeBody = nnkStmtList.newTree()
    for kk in allRoute[k].keys():
      let argvar = newIdentNode("args")
      let s = genSym(nskLabel)
      let body = allRoute[k][kk]
      let parsedRoute = kk.parseRoute.Route
      routeBody.add quote do:
        block `s`:
          let `argvar` = `parsedRoute`.matchRoute(`reqVarName`.url.path)
          if ((StringTableRef)(`argvar`)) == nil: break `s`
          `body`
    let s = genSym(nskLabel)
    result.add quote do:
      block `s`:
        if $(`reqVarName`.reqMethod) != `v`: break `s`
        `routeBody`

