import std/[asynchttpserver, cookies]
import std/[strtabs, tables, times]
from std/options import none, Option

type
  CookieCommand = tuple
    key: string
    value: string
    domain: string
    path: string
    expires: string
    noName: bool
    secure: bool
    httpOnly: bool
    maxAge: Option[int]
    sameSite: SameSite
  CookieCommandList* = TableRef[string, CookieCommand]

proc cookies*(x: Request): StringTableRef =
  return x.headers.getOrDefault("cookie").parseCookies

proc setCookie*(
  x: CookieCommandList, key: string, val: string,
  domain: string = "", path: string = "", expires: string = "",
  noName: bool = false, secure: bool = false,
  httpOnly: bool = false,
  maxAge = none(int),
  sameSite = SameSite.Default
): void =
  if not x.hasKey(key):
    x[key] = (
      key: key, value: val,
      domain: domain,
      path: path,
      expires: expires,
      noName: noName,
      secure: secure,
      httpOnly: httpOnly,
      maxAge: maxAge,
      sameSite: sameSite
    )
  else:
    x[key].key = key
    x[key].value = val
    x[key].domain = domain
    x[key].path = path
    x[key].expires = expires
    x[key].noName = noName
    x[key].secure = secure
    x[key].httpOnly = httpOnly
    x[key].maxAge = maxAge
    x[key].sameSite = sameSite

proc deleteCookie*(x: CookieCommandList, key: string): void =
  let cookieRemovingDT = now() - initDuration(days=7)
  let s = cookieRemovingDT.utc.format("ddd, dd MMM YYYY HH:mm:ss")
  x.setCookie(key, "", expires=s & " GMT")

proc toHeader*(x: CookieCommandList): seq[(string, string)] =
  var res: seq[(string, string)] = @[]
  for k in x.keys:
    res.add(("Set-Cookie", setCookie(
      k,
      x[k].value,
      domain=x[k].domain,
      path=x[k].path,
      expires=x[k].expires,
      noName=x[k].noName,
      secure=x[k].secure,
      httpOnly=x[k].httpOnly,
      maxAge=x[k].maxAge,
      sameSite=x[k].sameSite
    )))
  return res

