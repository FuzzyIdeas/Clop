//
//  SizeNotificationView.swift
//  Clop
//
//  Created by Alin Panaitiu on 26.07.2022.
//

import SwiftUI

extension Int {
    var humanSize: String {
        switch self {
        case 0 ..< 1000:
            return "\(self)B"
        case 0 ..< 1_000_000:
            return "\(self / 1000)KB"
        case 0 ..< 1_000_000_000:
            return "\(self / 1_000_000)MB"
        default:
            return "\(self / 1_000_000_000)GB"
        }
    }
}

// MARK: - SizeNotificationView

struct SizeNotificationView: View {
    @ObservedObject var optimizer: Optimizer

    var body: some View {
        HStack {
            HStack {
                if optimizer.running {
                    ProgressView().progressViewStyle(.circular).controlSize(.small)
                } else {
                    Text(optimizer.oldBytes.humanSize)
                        .font(.system(size: 13, weight: .semibold, design: .monospaced))
                        .foregroundColor(.red)
                    Image(systemName: "arrow.right")
                    Text(optimizer.newBytes.humanSize)
                        .font(.system(size: 13, weight: .semibold, design: .monospaced))
                        .foregroundColor(optimizer.newBytes < optimizer.oldBytes ? .blue : .red)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
            .background(.regularMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .transition(.opacity.animation(.easeOut(duration: 0.2)))
            Image("clop")
                .resizable()
                .scaledToFit()
                .frame(width: 30, height: 30, alignment: .center)
        }
        .padding()
        .frame(width: 400, alignment: .trailing)
        .fixedSize()
    }
}

// MARK: - SizeNotificationView_Previews

struct SizeNotificationView_Previews: PreviewProvider {
    static var previews: some View {
        SizeNotificationView(optimizer: Optimizer())
            .padding()
            .background(LinearGradient(colors: [.red, .orange, .blue], startPoint: .topLeading, endPoint: .bottomTrailing))
        SizeNotificationView(optimizer: Optimizer(running: false, oldBytes: 750_190, newBytes: 211_932))
            .padding()
            .background(LinearGradient(colors: [.red, .orange, .blue], startPoint: .topLeading, endPoint: .bottomTrailing))
    }
}
