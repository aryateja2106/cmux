import SwiftUI

/// Transparent overlay that renders an animated pointer to a target element.
/// Adapted from Clicky's bezier arc animation.
/// Applied as an `.overlay` on sibling panel views when the assistant points at something.
struct AssistantPointingOverlay: View {
    let target: PointTarget
    let containerSize: CGSize

    @State private var animationProgress: CGFloat = 0
    @State private var bubbleScale: CGFloat = 0.5
    @State private var bubbleOpacity: Double = 0

    /// Normalized position (0-1) within the container.
    private var normalizedX: CGFloat {
        guard containerSize.width > 0 else { return 0.5 }
        return min(max(target.x / containerSize.width, 0), 1)
    }

    private var normalizedY: CGFloat {
        guard containerSize.height > 0 else { return 0.5 }
        return min(max(target.y / containerSize.height, 0), 1)
    }

    private var targetPoint: CGPoint {
        CGPoint(
            x: normalizedX * containerSize.width,
            y: normalizedY * containerSize.height
        )
    }

    var body: some View {
        ZStack {
            // Pulsing ring at target
            Circle()
                .stroke(Color.blue.opacity(0.6), lineWidth: 2)
                .frame(width: 24 + animationProgress * 8, height: 24 + animationProgress * 8)
                .scaleEffect(1 + animationProgress * 0.3)
                .opacity(1 - animationProgress * 0.3)
                .position(targetPoint)

            // Solid dot at target
            Circle()
                .fill(Color.blue)
                .frame(width: 8, height: 8)
                .shadow(color: .blue.opacity(0.5), radius: 6)
                .position(targetPoint)

            // Label bubble
            if !target.label.isEmpty {
                labelBubble
                    .scaleEffect(bubbleScale)
                    .opacity(bubbleOpacity)
                    .position(bubblePosition)
            }
        }
        .allowsHitTesting(false)
        .onAppear {
            startAnimation()
        }
    }

    private var labelBubble: some View {
        HStack(spacing: 4) {
            Image(systemName: "scope")
                .font(.system(size: 9))
            Text(target.label)
                .font(.system(size: 10, weight: .medium, design: .monospaced))
        }
        .foregroundColor(.white)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color.blue.opacity(0.85))
        .cornerRadius(4)
        .shadow(color: .blue.opacity(0.3), radius: 4)
    }

    /// Position the label bubble offset from the target, avoiding edges.
    private var bubblePosition: CGPoint {
        let offsetY: CGFloat = normalizedY < 0.3 ? 28 : -28
        let clampedX = min(max(targetPoint.x, 40), containerSize.width - 40)
        return CGPoint(x: clampedX, y: targetPoint.y + offsetY)
    }

    private func startAnimation() {
        // Pulse animation (repeating)
        withAnimation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true)) {
            animationProgress = 1
        }

        // Bubble pop-in
        withAnimation(.spring(response: 0.3, dampingFraction: 0.7).delay(0.2)) {
            bubbleScale = 1.0
            bubbleOpacity = 1.0
        }
    }
}
