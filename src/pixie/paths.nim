import vmath, images, chroma, strutils, algorithm, common, bumpy, blends

type
  WindingRule* = enum
    wrNonZero
    wrEvenOdd

  PathCommandKind* = enum
    ## Type of path commands
    Close,
    Move, Line, HLine, VLine, Cubic, SCubic, Quad, TQuad, Arc,
    RMove, RLine, RHLine, RVLine, RCubic, RSCubic, RQuad, RTQuad, RArc

  PathCommand* = object
    ## Binary version of an SVG command
    kind*: PathCommandKind
    numbers*: seq[float32]

  Path* = ref object
    at*: Vec2
    commands*: seq[PathCommand]

proc newPath*(): Path =
  result = Path()

proc parameterCount(kind: PathCommandKind): int =
  case kind:
  of Close: 0
  of Move, Line, RMove, RLine: 2
  of HLine, VLine, RHLine, RVLine: 1
  of Cubic, RCubic: 6
  of SCubic, RSCubic, Quad, RQuad: 4
  of TQuad, RTQuad: 2
  of Arc, RArc: 7

proc parsePath*(path: string): Path =
  ## Converts a SVG style path into seq of commands.
  result = newPath()

  if path.len == 0:
    return

  var
    p, numberStart: int
    armed: bool
    kind: PathCommandKind
    numbers: seq[float32]

  proc finishNumber() =
    if numberStart > 0:
      try:
        numbers.add(parseFloat(path[numberStart ..< p]))
      except ValueError:
        raise newException(PixieError, "Invalid path, parsing paramter failed")
    numberStart = 0

  proc finishCommand(result: var Path) =
    finishNumber()

    if armed: # The first finishCommand() arms
      let paramCount = parameterCount(kind)
      if paramCount == 0:
        if numbers.len != 0:
          raise newException(PixieError, "Invalid path, unexpected paramters")
        result.commands.add(PathCommand(kind: kind))
      else:
        if numbers.len mod paramCount != 0:
          raise newException(
            PixieError,
            "Invalid path, wrong number of parameters"
          )
        for batch in 0 ..< numbers.len div paramCount:
          result.commands.add(PathCommand(
            kind: kind,
            numbers: numbers[batch * paramCount ..< (batch + 1) * paramCount]
          ))
        numbers.setLen(0)

    armed = true

  while p < path.len:
    case path[p]:
    # Relative
    of 'm':
      finishCommand(result)
      kind = RMove
    of 'l':
      finishCommand(result)
      kind = RLine
    of 'h':
      finishCommand(result)
      kind = RHLine
    of 'v':
      finishCommand(result)
      kind = RVLine
    of 'c':
      finishCommand(result)
      kind = RCubic
    of 's':
      finishCommand(result)
      kind = RSCubic
    of 'q':
      finishCommand(result)
      kind = RQuad
    of 't':
      finishCommand(result)
      kind = RTQuad
    of 'a':
      finishCommand(result)
      kind = RArc
    of 'z':
      finishCommand(result)
      kind = Close
    # Absolute
    of 'M':
      finishCommand(result)
      kind = Move
    of 'L':
      finishCommand(result)
      kind = Line
    of 'H':
      finishCommand(result)
      kind = HLine
    of 'V':
      finishCommand(result)
      kind = VLine
    of 'C':
      finishCommand(result)
      kind = Cubic
    of 'S':
      finishCommand(result)
      kind = SCubic
    of 'Q':
      finishCommand(result)
      kind = Quad
    of 'T':
      finishCommand(result)
      kind = TQuad
    of 'A':
      finishCommand(result)
      kind = Arc
    of 'Z':
      finishCommand(result)
      kind = Close
    of '-', '+':
      if numberStart > 0 and path[p - 1] in {'e', 'E'}:
        discard
      else:
        finishNumber()
        numberStart = p
    of ' ', ',', '\r', '\n', '\t':
      finishNumber()
    else:
      if numberStart == 0:
        numberStart = p

    inc p

  finishCommand(result)

proc `$`*(path: Path): string =
  for i, command in path.commands:
    case command.kind
    of Move: result.add "M"
    of Line: result.add "L"
    of HLine: result.add "H"
    of VLine: result.add "V"
    of Cubic: result.add "C"
    of SCubic: result.add "S"
    of Quad: result.add "Q"
    of TQuad: result.add "T"
    of Arc: result.add "A"
    of RMove: result.add "m"
    of RLine: result.add "l"
    of RHLine: result.add "h"
    of RVLine: result.add "v"
    of RCubic: result.add "c"
    of RSCubic: result.add "s"
    of RQuad: result.add "q"
    of RTQuad: result.add "t"
    of RArc: result.add "a"
    of Close: result.add "Z"
    for j, number in command.numbers:
      if floor(number) == number:
        result.add $number.int
      else:
        result.add $number
      if i != path.commands.len - 1 or j != command.numbers.len - 1:
        result.add " "

proc commandsToPolygons*(commands: seq[PathCommand]): seq[seq[Vec2]] =
  ## Converts SVG-like commands to simpler polygon

  var start, at, to, ctr, ctr2: Vec2
  var prevCommand: PathCommandKind

  var polygon: seq[Vec2]

  proc drawLine(at, to: Vec2) =
    # Don't add any 0 length lines.
    if at - to != vec2(0, 0):
      # Don't double up points.
      if polygon.len == 0 or polygon[^1] != at:
        polygon.add(at)
      polygon.add(to)

  proc drawCurve(at, ctrl1, ctrl2, to: Vec2) =

    proc compute(at, ctrl1, ctrl2, to: Vec2, t: float32): Vec2 {.inline.} =
      pow(1 - t, 3) * at +
      3 * pow(1 - t, 2) * t * ctrl1 +
      3 * (1 - t) * pow(t, 2) * ctrl2 +
      pow(t, 3) * to

    var prev = at

    proc discretize(i, steps: int) =
      let
        tPrev = (i - 1).float32 / steps.float32
        t = i.float32 / steps.float32
        next = compute(at, ctrl1, ctrl2, to, t)
        halfway = compute(at, ctrl1, ctrl2, to, tPrev + (t - tPrev) / 2)
        midpoint = (prev + next) / 2
        error = (midpoint - halfway).length

      if error >= 0.25:
        # Error too large, double precision for this step
        discretize(i * 2 - 1, steps * 2)
        discretize(i * 2, steps * 2)
      else:
        drawLine(prev, next)
        prev = next

    discretize(1, 1)

  proc drawQuad(p0, p1, p2: Vec2) =
    let devx = p0.x - 2.0 * p1.x + p2.x
    let devy = p0.y - 2.0 * p1.y + p2.y
    let devsq = devx * devx + devy * devy
    if devsq < 0.333:
      drawLine(p0, p2)
      return
    let tol = 3.0
    let n = 1 + (tol * (devsq)).sqrt().sqrt().floor()
    var p = p0
    let nrecip = 1 / n
    var t = 0.0
    for i in 0 ..< int(n):
      t += nrecip
      let pn = lerp(lerp(p0, p1, t), lerp(p1, p2, t), t)
      drawLine(p, pn)
      p = pn

    drawLine(p, p2)

  proc drawArc(
    at, radii: Vec2,
    rotation: float32,
    large, sweep: bool,
    to: Vec2
  ) =
    type ArcParams = object
      radii: Vec2
      rotMat: Mat3
      center: Vec2
      theta, delta: float32

    proc endpointToCenterArcParams(
      at, radii: Vec2, rotation: float32, large, sweep: bool, to: Vec2
    ): ArcParams =
      var
        radii = vec2(abs(radii.x), abs(radii.y))
        radiiSq = vec2(radii.x * radii.x, radii.y * radii.y)

      let
        radians = rotation / 180 * PI
        d = vec2((at.x - to.x) / 2.0, (at.y - to.y) / 2.0)
        p = vec2(
          cos(radians) * d.x + sin(radians) * d.y,
          -sin(radians) * d.x + cos(radians) * d.y
        )
        pSq = vec2(p.x * p.x, p.y * p.y)

      let cr = pSq.x / radiiSq.x + pSq.y / radiiSq.y
      if cr > 1:
        radii *= sqrt(cr)
        radiiSq = vec2(radii.x * radii.x, radii.y * radii.y)

      let
        dq = radiiSq.x * pSq.y + radiiSq.y * pSq.x
        pq = (radiiSq.x * radiiSq.y - dq) / dq

      var q = sqrt(max(0, pq))
      if large == sweep:
          q = -q

      proc svgAngle(u, v: Vec2): float32 =
        let
          dot = dot(u,v)
          len = length(u) * length(v)
        result = arccos(clamp(dot / len, -1, 1))
        if (u.x * v.y - u.y * v.x) < 0:
            result = -result

      let
        cp = vec2(q * radii.x * p.y / radii.y, -q * radii.y * p.x / radii.x)
        center = vec2(
          cos(radians) * cp.x - sin(radians) * cp.y + (at.x + to.x) / 2,
          sin(radians) * cp.x + cos(radians) * cp.y + (at.y + to.y) / 2
        )
        theta = svgAngle(vec2(1, 0), vec2((p.x-cp.x) / radii.x, (p.y - cp.y) / radii.y))

      var delta = svgAngle(
          vec2((p.x - cp.x) / radii.x, (p.y - cp.y) / radii.y),
          vec2((-p.x - cp.x) / radii.x, (-p.y - cp.y) / radii.y)
        )
      delta = delta mod (PI * 2)

      if not sweep:
        delta -= 2 * PI

      # Normalize the delta
      while delta > PI * 2:
        delta -= PI * 2
      while delta < -PI * 2:
        delta += PI * 2

      ArcParams(
        radii: radii,
        rotMat: rotationMat3(-radians),
        center: center,
        theta: theta,
        delta: delta
      )

    proc compute(arc: ArcParams, a: float32): Vec2 =
      result = vec2(cos(a) * arc.radii.x, sin(a) * arc.radii.y)
      result = arc.rotMat * result + arc.center

    var prev = at

    proc discretize(arc: ArcParams, i, steps: int) =
      let
        step = arc.delta / steps.float32
        aPrev = arc.theta + step * (i - 1).float32
        a = arc.theta + step * i.float32
        next = arc.compute(a)
        halfway = arc.compute(aPrev + (a - aPrev) / 2)
        midpoint = (prev + next) / 2
        error = (midpoint - halfway).length

      if error >= 0.25:
        # Error too large, try again with doubled precision
        discretize(arc, i * 2 - 1, steps * 2)
        discretize(arc, i * 2, steps * 2)
      else:
        drawLine(prev, next)
        prev = next

    let arc = endpointToCenterArcParams(at, radii, rotation, large, sweep, to)
    discretize(arc, 1, 1)

  for command in commands:
    case command.kind
      of Move:
        assert command.numbers.len == 2
        at.x = command.numbers[0]
        at.y = command.numbers[1]
        start = at

      of Line:
        assert command.numbers.len == 2
        to.x = command.numbers[0]
        to.y = command.numbers[1]
        drawLine(at, to)
        at = to

      of VLine:
        assert command.numbers.len == 1
        to.x = at.x
        to.y = command.numbers[0]
        drawLine(at, to)
        at = to

      of HLine:
        assert command.numbers.len == 1
        to.x = command.numbers[0]
        to.y = at.y
        drawLine(at, to)
        at = to

      of Quad:
        assert command.numbers.len mod 4 == 0
        var i = 0
        while i < command.numbers.len:
          ctr.x = command.numbers[i+0]
          ctr.y = command.numbers[i+1]
          to.x = command.numbers[i+2]
          to.y = command.numbers[i+3]

          drawQuad(at, ctr, to)
          at = to
          i += 4

      of TQuad:
        if prevCommand != Quad and prevCommand != TQuad:
          ctr = at
        assert command.numbers.len == 2
        to.x = command.numbers[0]
        to.y = command.numbers[1]
        ctr = at - (ctr - at)
        drawQuad(at, ctr, to)
        at = to

      of Cubic:
        assert command.numbers.len == 6
        ctr.x = command.numbers[0]
        ctr.y = command.numbers[1]
        ctr2.x = command.numbers[2]
        ctr2.y = command.numbers[3]
        to.x = command.numbers[4]
        to.y = command.numbers[5]
        drawCurve(at, ctr, ctr2, to)
        at = to

      of Arc:
        let
          radii = vec2(command.numbers[0], command.numbers[1])
          rotation = command.numbers[2]
          large = command.numbers[3] == 1
          sweep = command.numbers[4] == 1
          to = vec2(command.numbers[5], command.numbers[6])
        drawArc(at, radii, rotation, large, sweep, to)
        at = to

      of Close:
        assert command.numbers.len == 0
        if at != start:
          if prevCommand == Quad or prevCommand == TQuad:
            drawQuad(at, ctr, start)
          else:
            drawLine(at, start)
        if polygon.len > 0:
          result.add(polygon)
        polygon = newSeq[Vec2]()
        at = start

      of RMove:
        assert command.numbers.len == 2
        at.x += command.numbers[0]
        at.y += command.numbers[1]
        start = at

      of RLine:
        assert command.numbers.len == 2
        to.x = at.x + command.numbers[0]
        to.y = at.y + command.numbers[1]
        drawLine(at, to)
        at = to

      of RVLine:
        assert command.numbers.len == 1
        to.x = at.x
        to.y = at.y + command.numbers[0]
        drawLine(at, to)
        at = to

      of RHLine:
        assert command.numbers.len == 1
        to.x = at.x + command.numbers[0]
        to.y = at.y
        drawLine(at, to)
        at = to

      of RQuad:
        assert command.numbers.len == 4
        ctr.x = at.x + command.numbers[0]
        ctr.y = at.y + command.numbers[1]
        to.x = at.x + command.numbers[2]
        to.y = at.y + command.numbers[3]
        drawQuad(at, ctr, to)
        at = to

      of RTQuad:
        if prevCommand != RQuad and prevCommand != RTQuad:
          ctr = at
        assert command.numbers.len == 2
        to.x = at.x + command.numbers[0]
        to.y = at.y + command.numbers[1]
        ctr = at - (ctr - at)
        drawQuad(at, ctr, to)
        at = to

      of RCubic:
        assert command.numbers.len == 6
        ctr.x = at.x + command.numbers[0]
        ctr.y = at.y + command.numbers[1]
        ctr2.x = at.x + command.numbers[2]
        ctr2.y = at.y + command.numbers[3]
        to.x = at.x + command.numbers[4]
        to.y = at.y + command.numbers[5]
        drawCurve(at, ctr, ctr2, to)
        at = to

      of RSCubic:
        assert command.numbers.len == 4
        if prevCommand in {Cubic, SCubic, RCubic, RSCubic}:
          ctr = 2 * at - ctr2
        else:
          ctr = at
        ctr2.x = at.x + command.numbers[0]
        ctr2.y = at.y + command.numbers[1]
        to.x = at.x + command.numbers[2]
        to.y = at.y + command.numbers[3]
        drawCurve(at, ctr, ctr2, to)
        at = to

      else:
       raise newException(ValueError, "not supported path command " & $command)

    prevCommand = command.kind

  if polygon.len > 0:
    result.add(polygon)

iterator zipline*[T](s: seq[T]): (T, T) =
  ## Return elements in pairs: (1st, 2nd), (2nd, 3rd) ... (nth, last).
  for i in 0 ..< s.len - 1:
    yield(s[i], s[i + 1])

iterator segments*(s: seq[Vec2]): Segment =
  ## Return elements in pairs: (1st, 2nd), (2nd, 3rd) ... (last, 1st).
  for i in 0 ..< s.len - 1:
    yield(Segment(at: s[i], to: s[i + 1]))
  # if s.len > 0:
  #   let
  #     first = s[0]
  #     last = s[^1]
    # if first != last:
    #   yield(Segment(at: s[^1], to: s[0]))

proc strokePolygons*(ps: seq[seq[Vec2]], strokeWidthR, strokeWidthL: float32): seq[seq[Vec2]] =
  ## Converts simple polygons into stroked versions:
  # TODO: Stroke location, add caps and joins.
  for p in ps:
    var poly: seq[Vec2]
    var back: seq[Vec2] # Back side of poly.
    var prevRSeg: Segment
    var prevLSeg: Segment
    var first = true
    for (at, to) in p.zipline:
      let tangent = (at - to).normalize()
      let normal = vec2(-tangent.y, tangent.x)

      var
        rSeg = segment(at + normal * strokeWidthR, to + normal * strokeWidthR)
        lSeg = segment(at - normal * strokeWidthL, to - normal * strokeWidthL)

      if first:
        first = false
        # TODO: draw start cap
      else:
        var touch: Vec2
        if intersects(prevRSeg, rSeg, touch):
          rSeg.at = touch
          poly.setLen(poly.len - 1)
        else:
          discard # TODO: draw joint

        if intersects(prevLSeg, lSeg, touch):
          lSeg.at = touch
          back.setLen(back.len - 1)
        else:
          discard # TODO: draw joint

      poly.add rSeg.at
      back.add lSeg.at
      poly.add rSeg.to
      back.add lSeg.to

      prevRSeg = rSeg
      prevLSeg = lSeg

    # Add the backside reversed:
    for i in 1 .. back.len:
      poly.add back[^i]

    # TODO: draw end cap
    # Cap it at the end:
    poly.add poly[0]

    result.add(poly)

proc computeBounds(poly: seq[Vec2]): Rect =
  if poly.len == 0:
    return
  proc min(a, b: Vec2): Vec2 =
    result.x = min(a.x, b.x)
    result.y = min(a.y, b.y)
  proc max(a, b: Vec2): Vec2 =
    result.x = max(a.x, b.x)
    result.y = max(a.y, b.y)
  proc floor(a: Vec2): Vec2 =
    result.x = a.x.floor
    result.y = a.y.floor
  proc ceil(a: Vec2): Vec2 =
    result.x = a.x.ceil
    result.y = a.y.ceil
  var
    vMin = poly[0]
    vMax = poly[0]
  for v in poly:
    vMin = min(v, vMin)
    vMax = max(v, vMax)
  result.xy = vMin.floor
  result.wh = (vMax - vMin).ceil

{.push checks: off, stacktrace: off.}

proc fillPolygons*(
  image: Image,
  size: Vec2,
  polys: seq[seq[Vec2]],
  color: ColorRGBA,
  windingRule: WindingRule,
  blendMode: BlendMode = bmNormal,
  quality = 4
) =
  var bounds = newSeq[Rect](polys.len)
  for i, poly in polys:
    bounds[i] = computeBounds(poly)

  const ep = 0.0001 * PI
  let mixer = blendMode.mixer()

  proc scanLineHits(
    polys: seq[seq[Vec2]],
    bounds: seq[Rect],
    hits: var seq[(float32, bool)],
    size: Vec2,
    y: int,
    shiftY: float32
  ) {.inline.} =
    hits.setLen(0)

    let
      yLine = y.float32 + ep + shiftY
      scan = Line(a: vec2(-10000, yLine), b: vec2(10000, yLine))

    for i, poly in polys:
      let bounds = bounds[i]
      if bounds.y > y.float32 or bounds.y + bounds.h < y.float32:
        continue
      for line in poly.segments:
        if line.at.y == line.to.y: # Skip horizontal lines
          continue
        var line2 = line
        if line2.at.y > line2.to.y: # Sort order doesn't actually matter
          swap(line2.at, line2.to)
        # Lines often connect and we need them to not share starts and ends
        var at: Vec2
        if line2.intersects(scan, at) and line2.to != at:
          let
            winding = line.at.y > line.to.y
            x = at.x.clamp(0, size.x)
          hits.add((x, winding))

    hits.sort(proc(a, b: (float32, bool)): int = cmp(a[0], b[0]))

  var
    hits = newSeq[(float32, bool)]()
    alphas = newSeq[float32](image.width)
  for y in 0 ..< image.height:
    # Reset alphas for this row.
    zeroMem(alphas[0].addr, alphas.len * 4)

    # Do scan lines for this row.
    for m in 0 ..< quality:
      polys.scanLineHits(bounds, hits, size, y, float32(m) / float32(quality))
      if hits.len == 0:
        continue
      var
        penFill = 0
        curHit = 0
      for x in 0 ..< image.width:
        var penEdge: float32
        case windingRule
        of wrNonZero:
          penEdge = penFill.float32
        of wrEvenOdd:
          if penFill mod 2 == 0:
            penEdge = 0.0
          else:
            penEdge = 1.0

        while true:
          if curHit >= hits.len or x != hits[curHit][0].int:
            break
          let
            cover = hits[curHit][0] - x.float32
            winding = hits[curHit][1]
          if winding == false:
            penFill += 1
            penEdge += 1.0 - cover
          else:
            penFill -= 1
            penEdge -= 1.0 - cover
          inc curHit
        alphas[x] += penEdge

    for x in 0 ..< image.width:
      let a = clamp(abs(alphas[x]) / float32(quality), 0.0, 1.0)
      if a > 0:
        var colorWithAlpha = color
        colorWithAlpha.a = uint8(a * 255.0)
        let rgba = image.getRgbaUnsafe(x, y)
        image.setRgbaUnsafe(x, y, mixer(rgba, colorWithAlpha))

{.pop.}

type SomePath = seq[seq[Vec2]] | string | Path | seq[PathCommand]

proc parseSomePath(path: SomePath): seq[seq[Vec2]] =
  ## Given some path, turns it into polys.
  when type(path) is string:
    commandsToPolygons(parsePath(path).commands)
  elif type(path) is Path:
    commandsToPolygons(path.commands)
  elif type(path) is seq[PathCommand]:
    commandsToPolygons(path)
  elif type(path) is seq[seq[Vec2]]:
    path

proc fillPath*(
  image: Image,
  path: SomePath,
  color: ColorRGBA,
  windingRule = wrNonZero
) =
  let
    polys = parseSomePath(path)
  image.fillPolygons(image.wh, polys, color, windingRule)

proc fillPath*(
  image: Image,
  path: SomePath,
  color: ColorRGBA,
  pos: Vec2,
  windingRule = wrNonZero
) =
  var polys = parseSomePath(path)
  for poly in polys.mitems:
    for i, p in poly.mpairs:
      poly[i] = p + pos
  image.fillPolygons(image.wh, polys, color, windingRule)

proc fillPath*(
  image: Image,
  path: SomePath,
  color: ColorRGBA,
  mat: Mat3,
  windingRule = wrNonZero
) =
  var polys = parseSomePath(path)
  for poly in polys.mitems:
    for i, p in poly.mpairs:
      poly[i] = mat * p
  image.fillPolygons(image.wh, polys, color, windingRule)

proc strokePath*(
  image: Image,
  path: Path,
  color: ColorRGBA,
  strokeWidth: float32 = 1.0,
  windingRule = wrNonZero
  # TODO: Add more params:
  # strokeLocation: StrokeLocation,
  # strokeCap: StorkeCap,
  # strokeJoin: StorkeJoin
) =
  let
    polys = parseSomePath(path)
    (strokeL, strokeR) = (strokeWidth/2, strokeWidth/2)
    polys2 = strokePolygons(polys, strokeL, strokeR)
  image.fillPath(polys2, color, windingRule)

proc strokePath*(
  image: Image,
  path: SomePath,
  color: ColorRGBA,
  strokeWidth: float32,
  windingRule = wrNonZero
) =
  image.strokePath(parsePath(path), color, strokeWidth)

proc strokePath*(
  image: Image,
  path: SomePath,
  color: ColorRGBA,
  strokeWidth: float32,
  pos: Vec2,
  windingRule = wrNonZero
) =
  var polys = parseSomePath(path)
  let (strokeL, strokeR) = (strokeWidth/2, strokeWidth/2)
  var polys2 = strokePolygons(polys, strokeL, strokeR)
  for poly in polys2.mitems:
    for i, p in poly.mpairs:
      poly[i] = p + pos
  image.fillPolygons(image.wh, polys2, color, windingRule)

proc strokePath*(
  image: Image,
  path: SomePath,
  color: ColorRGBA,
  strokeWidth: float32,
  mat: Mat3,
  windingRule = wrNonZero
) =
  var polys = parseSomePath(path)
  let (strokeL, strokeR) = (strokeWidth/2, strokeWidth/2)
  var polys2 = strokePolygons(polys, strokeL, strokeR)
  for poly in polys2.mitems:
    for i, p in poly.mpairs:
      poly[i] = mat * p
  image.fillPolygons(image.wh, polys2, color, windingRule)

proc addPath*(path: Path, other: Path) =
  ## Adds a path to the current path.
  path.commands &= other.commands

proc closePath*(path: Path) =
  ## Causes the point of the pen to move back to the start of the current sub-path. It tries to draw a straight line from the current point to the start. If the shape has already been closed or has only one point, this function does nothing.
  path.commands.add PathCommand(kind: Close)

proc moveTo*(path: Path, x, y: float32) =
  ## Moves the starting point of a new sub-path to the (x, y) coordinates.
  path.commands.add PathCommand(kind: Move, numbers: @[x, y])
  path.at = vec2(x, y)

proc moveTo*(path: Path, pos: Vec2) =
  path.moveTo(pos.x, pos.y)

proc lineTo*(path: Path, x, y: float32) =
  ## Connects the last point in the subpath to the (x, y) coordinates with a straight line.
  path.commands.add PathCommand(kind: Line, numbers: @[x, y])
  path.at = vec2(x, y)

proc lineTo*(path: Path, pos: Vec2) =
  path.lineTo(pos.x, pos.y)

proc bezierCurveTo*(path: Path, x1, y1, x2, y2, x3, y3: float32) =
  ## Adds a cubic Bézier curve to the path. It requires three points. The first two points are control points and the third one is the end point. The starting point is the last point in the current path, which can be changed using moveTo() before creating the Bézier curve.
  path.commands.add(PathCommand(kind: Cubic, numbers: @[
    x1, y1, x2, y2, x3, y3
  ]))

proc quadraticCurveTo*(path: Path) =
  ## Adds a quadratic Bézier curve to the current path.
  raise newException(ValueError, "not implemented")

proc arc*(path: Path) =
  ## Adds an arc to the path which is centered at (x, y) position with radius r starting at startAngle and ending at endAngle going in the given direction by anticlockwise (defaulting to clockwise).
  raise newException(ValueError, "not implemented")

proc arcTo*(path: Path, x1, y1, x2, y2, r: float32) =
  ## Adds a circular arc to the path with the given control points and radius, connected to the previous point by a straight line.

  const epsilon = 1e-6.float32

  if path.commands.len == 0:
    # Is this path empty? Move to (x1,y1).
    path.moveTo(x1, y1)

  var r = r
  if r < 0:
    # Is the radius negative? Flip it.
    r = -r

  var
    x21 = x2 - x1
    y21 = y2 - y1
    x01 = path.at.x - x1
    y01 = path.at.y - y1
    l01_2 = x01 * x01 + y01 * y01

  if not (l01_2 > epsilon):
    # Is (x1,y1) coincident with (x0,y0)? Do nothing.
    discard

  elif not (abs(y01 * x21 - y21 * x01) > epsilon) or r == 0:
    # // Or, are (x0,y0), (x1,y1) and (x2,y2) colinear?
    # // Equivalently, is (x1,y1) coincident with (x2,y2)?
    # // Or, is the radius zero? Line to (x1,y1).

    path.lineTo(x1, y1)

  else:
    # Draw an arc
    var
      x20 = x2 - path.at.x
      y20 = y2 - path.at.y
      l21_2 = x21 * x21 + y21 * y21
      l20_2 = x20 * x20 + y20 * y20
      l21 = sqrt(l21_2)
      l01 = sqrt(l01_2)
      l = r * tan((PI - arccos((l21_2 + l01_2 - l20_2) / (2 * l21 * l01))) / 2).float32
      t01 = l / l01
      t21 = l / l21

    # If the start tangent is not coincident with path.at, line to.
    if abs(t01 - 1) > epsilon:
      path.lineTo(x1 + t01 * x01, y1 + t01 * y01)

    path.at.x = x1 + t21 * x21
    path.at.y = y1 + t21 * y21
    path.commands.add(PathCommand(
      kind: Arc,
      numbers: @[
        r,
        r,
        0,
        0,
        if y01 * x20 > x01 * y20: 1 else: 0,
        path.at.x,
        path.at.y
      ]
    ))

proc ellipse*(path: Path) =
  ## Adds an elliptical arc to the path which is centered at (x, y) position with the radii radiusX and radiusY starting at startAngle and ending at endAngle going in the given direction by anticlockwise (defaulting to clockwise).
  raise newException(ValueError, "not implemented")

proc rect*(path: Path, x, y, w, h: float32) =
  ## Creates a path for a rectangle at position (x, y) with a size that is determined by width and height.
  path.moveTo(x, y)
  path.lineTo(x+w, y)
  path.lineTo(x+w, y+h)
  path.lineTo(x,   y+h)
  path.lineTo(x,   y)
  path.closePath()

proc polygon*(path: Path, x, y, size: float32, sides: int) =
  ## Draws a n sided regular polygon at x,y with size.
  let
    size = 80.0
    x = 100.0
    y = 100.0
  path.moveTo(x + size * cos(0.0), y + size * sin(0.0))
  for side in 0 .. sides:
    path.lineTo(
      x + size * cos(side.float32 * 2.0 * PI / sides.float32),
      y + size * sin(side.float32 * 2.0 * PI / sides.float32)
    )
