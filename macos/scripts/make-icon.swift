#!/usr/bin/env swift
import AppKit
import CoreGraphics
import Foundation

// 生成应用图标：圆角方形渐变底 + 三根递增的柱子 + 一段配额弧。
//
// 用代码画而不是塞一个二进制 png 进仓库：图标能跟着配色调整、可 diff、
// 也不必依赖任何设计工具。运行 `swift scripts/make-icon.swift <输出目录>` 即可重新生成。

let outputDir = CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : FileManager.default.currentDirectoryPath

/// macOS 图标的画布留白：内容占整体约 82%，与系统图标的视觉重量一致。
let contentInset = 0.09

func drawIcon(size: CGFloat) -> CGImage? {
    let scale = size / 1024.0
    guard let ctx = CGContext(
        data: nil,
        width: Int(size), height: Int(size),
        bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { return nil }

    ctx.setShouldAntialias(true)
    ctx.interpolationQuality = .high

    let inset = size * contentInset
    let rect = CGRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
    // macOS 圆角方形（squircle 近似）：圆角半径约为边长的 22.5%
    let corner = rect.width * 0.225

    // ── 底：深蓝 → 青 的对角渐变
    let path = CGPath(roundedRect: rect, cornerWidth: corner, cornerHeight: corner, transform: nil)
    ctx.saveGState()
    ctx.addPath(path)
    ctx.clip()

    let colors = [
        CGColor(red: 0.13, green: 0.32, blue: 0.72, alpha: 1),   // 深蓝
        CGColor(red: 0.10, green: 0.62, blue: 0.82, alpha: 1),   // 青
    ] as CFArray
    if let gradient = CGGradient(
        colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
        colors: colors, locations: [0, 1]
    ) {
        ctx.drawLinearGradient(
            gradient,
            start: CGPoint(x: rect.minX, y: rect.maxY),
            end: CGPoint(x: rect.maxX, y: rect.minY),
            options: []
        )
    }

    // 顶部高光，让平面渐变有一点体积感
    ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.14))
    ctx.addPath(CGPath(
        ellipseIn: CGRect(
            x: rect.minX - rect.width * 0.25, y: rect.midY,
            width: rect.width * 1.5, height: rect.height * 0.95
        ),
        transform: nil
    ))
    ctx.fillPath()
    ctx.restoreGState()

    // 小尺寸（菜单栏、列表行）下，弧线和柱子会糊成一团，
    // 所以 64px 以下只画放大的柱子 —— 与 Apple 自己按尺寸简化图形的做法一致。
    let detailed = size >= 64
    let center = CGPoint(x: rect.midX, y: rect.midY - rect.height * 0.02)

    if detailed {
        // ── 配额弧：一段留白的圆环，象征“额度”，缺口朝下
        let arcRadius = rect.width * 0.315
        let arcWidth = rect.width * 0.075

        ctx.setLineCap(.round)
        ctx.setLineWidth(arcWidth)

        // 轨道
        ctx.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.26))
        ctx.addArc(center: center, radius: arcRadius,
                   startAngle: .pi * 1.20, endAngle: .pi * -0.20, clockwise: true)
        ctx.strokePath()

        // 已用部分：约占轨道的 62%，暖色，一眼能和轨道区分
        ctx.setStrokeColor(CGColor(red: 1.0, green: 0.78, blue: 0.25, alpha: 1))
        let sweep = Double.pi * 1.40 * 0.62
        ctx.addArc(center: center, radius: arcRadius,
                   startAngle: .pi * 1.20, endAngle: .pi * 1.20 - sweep, clockwise: true)
        ctx.strokePath()
    }

    // ── 三根递增的柱子
    let barWidth = rect.width * (detailed ? 0.082 : 0.155)
    let gap = rect.width * (detailed ? 0.052 : 0.075)
    let heightRatios: [CGFloat] = detailed ? [0.155, 0.245, 0.335] : [0.26, 0.40, 0.54]
    let heights: [CGFloat] = heightRatios.map { rect.height * $0 }
    let totalWidth = barWidth * 3 + gap * 2
    let baseY = center.y - rect.height * (detailed ? 0.175 : 0.27)
    var x = center.x - totalWidth / 2

    for (index, h) in heights.enumerated() {
        // 小尺寸没有弧线，用最高一根的暖色顶替“已用”的语义
        if !detailed && index == heights.count - 1 {
            ctx.setFillColor(CGColor(red: 1.0, green: 0.78, blue: 0.25, alpha: 1))
        } else {
            ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.97))
        }
        let bar = CGRect(x: x, y: baseY, width: barWidth, height: h)
        ctx.addPath(CGPath(
            roundedRect: bar,
            cornerWidth: barWidth / 2, cornerHeight: barWidth / 2,
            transform: nil
        ))
        ctx.fillPath()
        x += barWidth + gap
    }

    _ = scale
    return ctx.makeImage()
}

func write(_ image: CGImage, to url: URL) throws {
    let rep = NSBitmapImageRep(cgImage: image)
    guard let data = rep.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "icon", code: 1)
    }
    try data.write(to: url)
}

// iconset 需要的全部尺寸（含 @2x）
let variants: [(name: String, size: CGFloat)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]

let iconset = URL(fileURLWithPath: outputDir).appendingPathComponent("VPSQuota.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

for v in variants {
    guard let image = drawIcon(size: v.size) else {
        FileHandle.standardError.write(Data("无法绘制 \(v.name)\n".utf8))
        exit(1)
    }
    try write(image, to: iconset.appendingPathComponent("\(v.name).png"))
}

print("✅ 已生成 \(iconset.path)（\(variants.count) 个尺寸）")
