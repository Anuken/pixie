import pixie, chroma, strutils, os, vmath

proc writeAndCheck(image: Image, fileName: string) =
  image.writeFile(fileName)
  let masterFileName = fileName.replace("tests/images/", "tests/images/masters/")
  if not fileExists(masterFileName):
    echo "Master file: " & masterFileName & " not found!"
    quit(-1)
  var master = readImage(fileName)
  assert image.width == master.width
  assert image.height == master.height
  assert image.data == master.data

# block:
#   var a = newImage(100, 100)
#   a.fill(rgba(0, 0, 0, 0))
#   var b = newImage(50, 50)
#   b.fill(rgba(255, 92, 0, 255))
#   var c = a.drawBlendSmooth(
#     b,
#     translate(vec2(50, 50)) * rotationMat3(0.2789281382) * translate(vec2(-25, -25)),
#     bmNormal
#   )
#   c.writeAndCheck("tests/images/centerRotation.png")

# block:
#   var a = newImage(100, 100)
#   a.fill(rgba(255, 255, 255, 255))
#   var b = newImage(50, 50)
#   b.fill(rgba(255, 92, 0, 255))
#   var c = a.drawBlendSmooth(
#     b,
#     translate(vec2(50, 50)) * rotationMat3(0.2789281382) * translate(vec2(-25, -25)),
#     bmNormal
#   )
#   c.writeAndCheck("tests/images/centerRotationWhite.png")


# block:
#   var a = newImage(100, 100)
#   a.fill(rgba(0, 0, 0, 0))
#   var b = newImage(50, 50)
#   b.fill(rgba(255, 92, 0, 255))
#   var c = a.drawBlendSmooth(
#     b,
#     translate(vec2(50, 50)) * rotationMat3(0.2789281382) * translate(vec2(-25, -25)),
#     bmNormal
#   )
#   c.writeAndCheck("tests/images/transCompose.c.png")
#   var d = newImage(100, 100)
#   d = d.fill(rgba(255, 255, 255, 255))
#   var e = d.draw(c)
#   e.writeAndCheck("tests/images/transCompose.png")

block:
  var image = newImage(10, 10)
  image[0, 0] = rgba(255, 255, 255, 255)
  doAssert image[0, 0] == rgba(255, 255, 255, 255)

block:
  var image = newImage(10, 10)
  image.fill(rgba(255, 0, 0, 255))
  doAssert image[0, 0] == rgba(255, 0, 0, 255)

block:
  var image = newImage(10, 10)
  image.fill(rgba(255, 0, 0, 128))
  image.toAlphy()
  doAssert image[9, 9] == rgba(128, 0, 0, 128)

block:
  var image = newImage(10, 10)
  image.fill(rgba(128, 0, 0, 128))
  image.fromAlphy()
  doAssert image[9, 9] == rgba(255, 0, 0, 128)

# block:
#   var a = newImage(100, 100)
#   a.fill(rgba(255, 0, 0, 255))
#   var b = newImage(100, 100)
#   b.fill(rgba(0, 255, 0, 255))
#   var c = a.drawOverwrite(b, translate(vec2(25, 25)))
#   c.writeAndCheck("tests/images/drawOverwrite.png")

# block:
#   var a = newImage(100, 100)
#   a.fill(rgba(255, 0, 0, 255))
#   var b = newImage(100, 100)
#   b.fill(rgba(0, 255, 0, 255))
#   var c = a.draw(b, translate(vec2(25, 25)), bmOverwrite)
#   c.writeAndCheck("tests/images/drawBlend.png")

# block:
#   var a = newImage(100, 100)
#   a.fill(rgba(255, 0, 0, 255))
#   var b = newImage(100, 100)
#   b.fill(rgba(0, 255, 0, 255))
#   var c = a.draw(b, translate(vec2(25.15, 25.15)), bmOverwrite)
#   c.writeAndCheck("tests/images/drawBlendSmooth.png")

# block:
#   var a = newImage(100, 100)
#   a.fill(rgba(255, 0, 0, 255))
#   var b = newImage(100, 100)
#   b.fill(rgba(0, 255, 0, 255))

#   var c = a.draw(b, translate(vec2(25, 25)) * rotationMat3(PI/2))
#   c.writeAndCheck("tests/images/drawOverwriteRot.png")

block:
  let
    a = newImage(101, 101)
    b = newImage(50, 50)

  a.fill(rgba(255, 0, 0, 255))
  b.fill(rgba(0, 255, 0, 255))

  a.draw(b, vec2(0, 0))

  a.writeFile("tests/images/flipped1.png")
  a.flipVertical()
  a.writeFile("tests/images/flipped2.png")
  a.flipHorizontal()
  a.writeFile("tests/images/flipped3.png")
