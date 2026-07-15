#!/usr/bin/env swift
// AppIcon 생성기 — 외부 의존성 없이 CoreGraphics로 아이콘을 그린다.
// 사용: swift scripts/gen-appicon.swift <variant 1-4> <output.png> [size]
// 디자인: 플랫 & 심플 — 단색 배경 + 단일 플랫 글리프, 효과 없음.
//   1024 캔버스, 824 라운드 사각형(코너 185, Big Sur 규격).
//   1 = 위치 핀 + 스파클 음각 (Anywhere=핀, LLM=스파클)
//   2 = 오프블랙 배경 + 흰 스파클 (미니멀)
//   3 = 오프화이트 배경 + 인디고 스파클 (라이트 미니멀)
//   4 = "A" 모노그램 + 스파클 액센트

import AppKit

let args = CommandLine.arguments
guard args.count >= 3, let variant = Int(args[1]) else {
    print("usage: gen-appicon.swift <variant 1-4> <output.png> [size]")
    exit(1)
}
let outPath = args[2]
let outSize = args.count >= 4 ? Int(args[3])! : 1024

// 모든 좌표는 1024 기준. 출력 크기에 맞춰 컨텍스트를 스케일.
let S: CGFloat = 1024

func color(_ hex: UInt32, _ a: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: a)
}

// 4점 스파클(AI 모티프): 꼭짓점 4개, 안쪽으로 휘는 곡선
func sparklePath(cx: CGFloat, cy: CGFloat, r: CGFloat, k: CGFloat = 0.18) -> NSBezierPath {
    let p = NSBezierPath()
    let q = r * k
    p.move(to: NSPoint(x: cx, y: cy + r))
    p.curve(to: NSPoint(x: cx + r, y: cy),
            controlPoint1: NSPoint(x: cx + q, y: cy + q),
            controlPoint2: NSPoint(x: cx + q, y: cy + q))
    p.curve(to: NSPoint(x: cx, y: cy - r),
            controlPoint1: NSPoint(x: cx + q, y: cy - q),
            controlPoint2: NSPoint(x: cx + q, y: cy - q))
    p.curve(to: NSPoint(x: cx - r, y: cy),
            controlPoint1: NSPoint(x: cx - q, y: cy - q),
            controlPoint2: NSPoint(x: cx - q, y: cy - q))
    p.curve(to: NSPoint(x: cx, y: cy + r),
            controlPoint1: NSPoint(x: cx - q, y: cy + q),
            controlPoint2: NSPoint(x: cx - q, y: cy + q))
    p.close()
    return p
}

// 위치 핀: 원형 헤드 + 아래로 모이는 꼬리
func pinPath(cx: CGFloat, headCY: CGFloat, headR: CGFloat, tipY: CGFloat) -> NSBezierPath {
    let p = NSBezierPath()
    let aL: CGFloat = 205, aR: CGFloat = 335
    let pL = NSPoint(x: cx + headR * cos(aL * .pi / 180), y: headCY + headR * sin(aL * .pi / 180))
    p.move(to: NSPoint(x: cx, y: tipY))
    p.curve(to: pL,
            controlPoint1: NSPoint(x: cx - headR * 0.32, y: tipY + (headCY - tipY) * 0.35),
            controlPoint2: NSPoint(x: cx - headR * 0.72, y: tipY + (headCY - tipY) * 0.62))
    p.appendArc(withCenter: NSPoint(x: cx, y: headCY), radius: headR,
                startAngle: aL, endAngle: aR - 360, clockwise: true)
    p.curve(to: NSPoint(x: cx, y: tipY),
            controlPoint1: NSPoint(x: cx + headR * 0.72, y: tipY + (headCY - tipY) * 0.62),
            controlPoint2: NSPoint(x: cx + headR * 0.32, y: tipY + (headCY - tipY) * 0.35))
    p.close()
    return p
}

let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: outSize, pixelsHigh: outSize,
                           bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                           colorSpaceName: .calibratedRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
let ctx = NSGraphicsContext(bitmapImageRep: rep)!
NSGraphicsContext.current = ctx
let cg = ctx.cgContext
cg.scaleBy(x: CGFloat(outSize) / S, y: CGFloat(outSize) / S)

// ---- 배경: 단색 라운드 사각형 ----
let bgRect = NSRect(x: 100, y: 100, width: 824, height: 824)
let bg = NSBezierPath(roundedRect: bgRect, xRadius: 185, yRadius: 185)

let indigo = color(0x5B5BD6)
let ink = color(0x111114)
let paper = color(0xF5F3EE)

switch variant {
case 1, 4: indigo.setFill()
case 2: ink.setFill()
default: paper.setFill()
}
bg.fill()

// ---- 글리프 (플랫 단색) ----
switch variant {
case 1:
    // 핀 + 스파클 음각
    let pin = pinPath(cx: 512, headCY: 590, headR: 216, tipY: 218)
    pin.windingRule = .evenOdd
    pin.append(sparklePath(cx: 512, cy: 594, r: 128, k: 0.24))
    NSColor.white.setFill()
    pin.fill()
case 2:
    NSColor.white.setFill()
    sparklePath(cx: 512, cy: 512, r: 250, k: 0.28).fill()
case 3:
    indigo.setFill()
    sparklePath(cx: 512, cy: 512, r: 250, k: 0.28).fill()
case 4:
    // "A" 모노그램 (SF Rounded Heavy) + 스파클 액센트
    let font = NSFont.systemFont(ofSize: 560, weight: .heavy)
    let rounded = NSFont(descriptor: font.fontDescriptor.withDesign(.rounded)!, size: 560) ?? font
    let str = NSAttributedString(string: "A", attributes: [.font: rounded, .foregroundColor: NSColor.white])
    let sz = str.size()
    str.draw(at: NSPoint(x: 512 - sz.width / 2 - 30, y: 512 - sz.height / 2 - 10))
    NSColor.white.setFill()
    sparklePath(cx: 748, cy: 730, r: 92).fill()
default: break
}

NSGraphicsContext.restoreGraphicsState()

let data = rep.representation(using: .png, properties: [:])!
try! data.write(to: URL(fileURLWithPath: outPath))
print("wrote \(outPath) (\(outSize)px, variant \(variant))")
