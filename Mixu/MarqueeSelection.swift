//
//  MarqueeSelection.swift
//  Mixu
//
//  Created by Johan Lescure on 18/09/2025.
//

import SwiftUI

struct MarqueeSelection: View {
    @Binding var startPoint: CGPoint?
    @Binding var currentPoint: CGPoint?
    @Binding var isMarqueeing: Bool
    let onMarqueeEnd: (CGRect) -> Void
    
    var body: some View {
        ZStack {
            if let start = startPoint, let current = currentPoint {
                Rectangle()
                    .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [4]))
                    .background(Rectangle().fill(Color.blue.opacity(0.15)))
                    .frame(width: abs(current.x - start.x),
                           height: abs(current.y - start.y))
                    .position(x: (start.x + current.x) / 2,
                              y: (start.y + current.y) / 2)
            }
        }
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    if startPoint == nil {
                        startPoint = value.startLocation
                    }
                    currentPoint = value.location
                    isMarqueeing = true
                }
                .onEnded { value in
                    if let start = startPoint, let current = currentPoint {
                        let marqueeRect = CGRect(
                            x: min(start.x, current.x),
                            y: min(start.y, current.y),
                            width: abs(current.x - start.x),
                            height: abs(current.y - start.y)
                        )
                        onMarqueeEnd(marqueeRect)
                    }
                    startPoint = nil
                    currentPoint = nil
                    isMarqueeing = false
                }
        )
    }
}
