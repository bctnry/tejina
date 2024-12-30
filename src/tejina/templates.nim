import std/macros
import std/parseutils
import std/strutils
import std/sequtils
import std/json
import std/sets
import std/tables
import std/paths

proc newProperty*(): JsonNode = return %*{}
proc `[]=`*(p: JsonNode, k: string, v: typeof(nil)): void =
    p[k] = %* v
proc `[]=`*(p: JsonNode, k: string, v: string): void =
    p[k] = %* v
proc `[]=`*(p: JsonNode, k: string, v: int): void =
    p[k] = %* v
proc `[]=`*(p: JsonNode, k: string, v: float): void =
    p[k] = %* v
proc `[]=`*(p: JsonNode, k: string, v: bool): void =
    p[k] = %* v
proc `[]=`*[A](p: JsonNode, k: string, v: seq[A]): void =
    p[k] = %* v
proc length*(p: JsonNode): int =
  if p.kind == JArray: return p.elems.len
  elif p.kind == JString: return p.str.len
  else:
    raise newException(ValueError, "Cannot take length of non-collections")
proc length*[A](x: A): int = x.len
proc `toDisplayStr`*(p: JsonNode): string =
  case p.kind:
    of JNull: "nil"
    of JString: p.str
    of JInt: $p.num
    of JFloat: $p.fnum
    of JBool: $p.bval
    of JArray: "[" & p.elems.mapIt($it).join(", ") & "]"
    of JObject:
      var r: seq[string] = @[]
      for k in p.fields.pairs:
        r.add(k[0].repr & ": " & $k[1])
      return "{" & r.join(", ") & "}"
proc `toDisplayStr`*(x: string): string = x
proc `toDisplayStr`*(x: int): string = $x
proc `toDisplayStr`*(x: float): string = $x
proc `toDisplayStr`*(x: typeof(nil)): string = "nil"
proc `toDisplayStr`*(x: bool): string = $x
proc `toDisplayStr`*[A](x: openArray[A]): string = $x
      
type
  TemplatePieceType* = enum
    STRING
    EXPR
    INCLUDE
    IF
    FOR
  TemplatePiece* {.acyclic.} = ref object
    case pType*: TemplatePieceType
    of STRING:
      strVal*: string
    of EXPR:
      exVal*: string
    of INCLUDE:
      includePath*: string
    of IF:
      ifClause*: seq[(string, seq[TemplatePiece])]
      elseClause*: seq[TemplatePiece]
    of FOR:
      forVar*: string
      forExpr*: string
      forBody*: seq[TemplatePiece]

proc `$`*(x: TemplatePiece): string =
  case x.pType:
    of STRING: x.strVal
    of EXPR: "{{" & x.exVal & "}}"
    of INCLUDE: "{{include " & x.includePath & "}}"
    of IF:
      let a = "{{"
      let b = x.ifClause.map(
        proc (k: (string, seq[TemplatePiece])): string =
          return "if " & k[0] & "}}" & $k[1].mapIt($it).join("")
      ).join("{{el")
      let c = "{{else}}" & $x.elseClause.mapIt($it).join("")
      return a & b & c & "{{/if}}"
    of FOR:
      "{{for " & x.forVar & " in " & x.forExpr & "}}" & x.forBody.mapIt($it).join("") & "{{/for}}"

proc takeFirstWord(x: string, target: var string, start: int = 0): int =
  var i = start
  let lenx = x.len
  target = ""
  while i < lenx:
    if i + 1 < lenx and x[i] == '}' and x[i+1] == '}': break
    if x[i] == ' ' or x[i] == '\t': break
    target.add(x[i])
    i += 1
  return i

# K stands for Kontinuation. The rest is obvious.
type
  KT = enum
    KIF
    KELIF
    KFOR
    KELSE
  K = ref object
    kOutside: seq[TemplatePiece]
    case kind: KT
    of KIF:
      kIfCond: string
    of KELIF:
      kElifCond: string
      kElifCompletedClause: seq[(string, seq[TemplatePiece])]
    of KELSE:
      kElseCompletedClause: seq[(string, seq[TemplatePiece])]
    of KFOR:
      kForBoundVar: string
      kForExpr: string
    
proc parseTemplate*(x: string, filename: string = ""): seq[TemplatePiece]=
  var ress: seq[K] = @[]
  var res: seq[TemplatePiece] = @[]
  var isTag = false
  var currentPiece = ""
  var i = 0
  let lenx = x.len
  var line = 1
  var col = 1
  while i < lenx:
    if x[i] == '{' and i+1 < lenx and x[i+1] == '{':
      if isTag:
        currentPiece.add('{')
        currentPiece.add('{')
        i += 2
      else:
        res.add(TemplatePiece(pType: STRING, strVal: currentPiece))
        currentPiece = ""
        isTag = true
        i += 2
      col += 2
    elif x[i] == '}' and i+1 < lenx and x[i+1] == '}':
      if not isTag:
        currentPiece.add('}')
        currentPiece.add('}')
        i += 2
      else:
        let t = currentPiece.strip()
        var firstId: string = ""
        var s = t.takeFirstWord(firstId)
        case firstId:
          of "/if":
            if ress.len <= 0:
              raise newException(ValueError, filename & "(" & $line & "," & $col & "): /if does not have a matching if")
            if ress[^1].kind != KIF and ress[^1].kind != KELIF and ress[^1].kind != KELSE:
              raise newException(ValueError, filename & "(" & $line & "," & $col & "): Cannot end a non-if with an /if.")
            var v = ress.pop()
            v.kOutside.add(
              case v.kind:
                of KIF:
                  TemplatePiece(pType: IF,
                                ifClause: @[(v.kIfCond, res)],
                                elseClause: @[])
                of KELIF:
                  TemplatePiece(pType: IF,
                                ifClause: (v.kElifCompletedClause & @[(v.kElifCond, res)]),
                                elseClause: @[])
                of KELSE:
                  TemplatePiece(pType: IF,
                                ifClause: v.kElseCompletedClause,
                                elseClause: res)
                else:
                  raise newException(ValueError, filename & "(" & $line & "," & $col & "): Cannot end a non-if with an /if.")
            )
            res = v.kOutside
          of "/for":
            if ress.len <= 0:
              raise newException(ValueError, filename & "(" & $line & "," & $col & "): /for does not have a matching for")
            if ress[^1].kind != KFOR:
              raise newException(ValueError, filename & "(" & $line & "," & $col & "): Cannot end a non-for with an /for.")
            var v = ress.pop()
            v.kOutside.add(
              TemplatePiece(pType: FOR,
                            forVar: v.kForBoundVar,
                            forExpr: v.kForExpr,
                            forBody: res)
            )
            res = v.kOutside
          of "include":
            res.add(TemplatePiece(pType: INCLUDE, includePath: t.substr(s).strip()))
          of "if":
            ress.add(K(kOutside: res, kind: KIF, kIfCond: t.substr(s).strip()))
            res = @[]
          of "elif":
            let kkkk = ress.pop()
            ress.add(K(kOutside: kkkk.kOutside,
                       kind: KELIF,
                       kElifCond: t.substr(s).strip(),
                       kElifCompletedClause:
                         case kkkk.kind:
                           of KIF:
                             @[(kkkk.kIfCond, res)]
                           of KELIF:
                             kkkk.kElifCompletedClause & @[(kkkk.kElifCond, res)]
                           else:
                             raise newException(ValueError, "couldn't happen")))
            res = @[]
          of "else":
            let kkkk = ress.pop()
            ress.add(K(kOutside: kkkk.kOutside,
                       kind: KELSE,
                       kElseCompletedClause:
                         case kkkk.kind:
                           of KIF:
                             @[(kkkk.kIfCond, res)]
                           of KELIF:
                             kkkk.kElifCompletedClause & @[(kkkk.kElifCond, res)]
                           else:
                             raise newException(ValueError, "couldn't happen")))
            res = @[]
          of "for":
            var boundVar: string = ""
            s += t.skipWhitespace(start=s)
            s += t.parseIdent(boundVar, start=s)
            s += t.skipWhitespace(start=s)
            var chk: string = ""
            s = t.takeFirstWord(chk, start=s)
            if chk != "in":
              raise newException(ValueError, filename & "(" & $line & "," & $col & "): \"in\" expected in a \"for\" tag.")
            s += t.skipWhitespace(start=s)
            var ex = t.substr(s).strip()
            ress.add(K(kOutside: res,
                       kind: KFOR,
                       kForBoundVar: boundVar,
                       kForExpr: ex))
            res = @[]
          else:
            res.add(TemplatePiece(pType: EXPR, exVal: currentPiece))
        currentPiece = ""
        isTag = false
        i += 2
        col += 2
    else:
      if isTag:
        currentPiece.add(x[i])
        if x[i] == '\n':
          line += 1
          col = 1
        elif x[i] != '\r': col += 1
        i += 1
      else:
        currentPiece.add(x[i])
        if x[i] == '\n':
          line += 1
          col = 1
        elif x[i] != '\r': col += 1
        i += 1
  if isTag and currentPiece.len > 0:
    currentPiece &= "{{" & currentPiece
  if currentPiece.len > 0:
    res.add(TemplatePiece(pType: STRING, strVal: currentPiece))

  if ress.len > 0:
    raise newException(ValueError, filename & "(" & $line & "," & $col & "): " & (case ress[^1].kind:
                                      of KFOR: "/for"
                                      of KIF: "/if"
                                      of KELIF: "/if"
                                      of KELSE: "/if") & " tag required")
  return res

proc resolveTemplate(filename: string, trail: var seq[string]): seq[TemplatePiece] =
  var res: seq[TemplatePiece] = @[]
  if filename in trail:
    trail.add(filename)
    raise newException(ValueError, "Cyclic inclusion detected. Trail: " & trail.join("-->"))
  let s = staticRead(filename)
  trail.add(filename)
  let v = s.parseTemplate(filename)
  for k in v:
    case k.pType:
      of INCLUDE:
        let newPath = (filename.Path.parentDir / k.includePath.Path).string
        res &= resolveTemplate(newPath, trail)
      else:
        res.add(k)
  discard trail.pop()
  return res
      
proc renderTemplateToAST(s: seq[TemplatePiece], resultVar: NimNode): NimNode =
  result = nnkStmtList.newTree()
  for k in s:
    case k.pType:
      of STRING:
        let key = k.strVal
        result.add quote do:
          `resultVar`.add(`key`)
      of EXPR:
        let v: NimNode = k.exVal.parseExpr
        result.add quote do:
          `resultVar`.add(`v`.toDisplayStr)
      of FOR:
        let v: NimNode = newIdentNode(k.forVar)
        let e: NimNode = k.forExpr.parseExpr
        let b: NimNode = k.forBody.renderTemplateToAST(resultVar)
        result.add quote do:
          for `v` in `e`:
            `b`
      of IF:
        if k.ifClause.len <= 0:
          raise newException(ValueError, "Cannot have zero if-branch.")
        var i = k.ifClause.len-1
        var lastCond = k.ifClause[i][0].parseExpr
        var lastIfBody = k.ifClause[i][1].renderTemplateToAST(resultVar)
        var lastRes =
          if k != nil and k.elseClause.len > 0:
            let elseBody = k.elseClause.renderTemplateToAST(resultVar)
            quote do:
              if `lastCond`:
                `lastIfBody`
              else:
                `elseBody`
          else:
            quote do:
              if `lastCond`:
                `lastIfBody`
        i -= 1
        while i >= 0:
          var branchCond= k.ifClause[i][0].parseExpr
          var branchBody = k.ifClause[i][1].renderTemplateToAST(resultVar)
          lastRes =
            quote do:
              if `branchCond`:
                `branchBody`
              else:
                `lastRes`
          i -= 1
        result.add lastRes
      of INCLUDE:
        raise newException(ValueError, "shouldn't happen")
  return result

## Usage:
##     defineTemplate [varName]: [template-path]
## This will load the file at `[template-path]` as a template and define a proc
## of type `proc (prop: JsonNode): string` named `[varName]`. Since `prop` is
## the only variable defined within the scope, you must pass everything through
## `prop` and use the format `proc["key"]` to access the values.
macro defineTemplate*(name: untyped, filename: static[string]): untyped =
  result = nnkStmtList.newTree()
  let resolveBase = (name.lineInfoObj.filename.Path).parentDir / filename.Path
  var trail: seq[string] = @[]
  let v = resolveBase.string.resolveTemplate(trail)
  let res = newIdentNode("`")
  let prop = newIdentNode("prop")
  let procBody = v.renderTemplateToAST(res)
  result.add quote do:
    proc `name`(`prop`: JsonNode): string =
      var `res`: seq[string] = @[]
      `procBody`
      return `res`.join("")
  # echo filename, " --> ", result.repr

## Usage:
##     expandTemplate([varName], [template-path])
## This will load the file at `[template-path]` as a template and expand it into
## a series of statements that, when executed, will store a string to the variable
## named `[varName]`. The expanded code relies on its scope having the necessary
## variables defined, so you must declare them beforehand, e.g. if you have this
## code in your template:
## ```
##     {{if someVar.len > 3}}
##         <h3>{{someVar}}</h3>
##     {{else}}
##         <h3>{{someOtherVar}}</h3>
##     {{/if}}
## ```
## You must have `someVar` and `someOtherVar` declared before you call `expandTemplate`.
macro expandTemplate*(resultVarName: untyped, filename: static[string]): untyped =
  result = nnkStmtList.newTree()
  let resolveBase = (resultVarName.lineInfoObj.filename.Path).parentDir / filename.Path
  var trail: seq[string] = @[]
  let v = resolveBase.string.resolveTemplate(trail)
  let seqres = newIdentNode("`")
  let procBody = v.renderTemplateToAST(seqres)
  result.add quote do:
    var `resultVarName`: string
    block:
      var `seqres`: seq[string] = @[]
      `procBody`
      `resultVarName` = `seqres`.join("")
    
