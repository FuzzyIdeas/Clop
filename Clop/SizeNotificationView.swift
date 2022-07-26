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
    @State var oldBytes: Int
    @State var newBytes: Int

    var body: some View {
        HStack {
            HStack {
                Text(oldBytes.humanSize)
                    .font(.system(size: 13, weight: .semibold, design: .monospaced))
                    .foregroundColor(.red)
                Image(systemName: "arrow.right")
                Text(newBytes.humanSize)
                    .font(.system(size: 13, weight: .semibold, design: .monospaced))
                    .foregroundColor(.blue)
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
        .fixedSize()
    }
}

// MARK: - SizeNotificationView_Previews

struct SizeNotificationView_Previews: PreviewProvider {
    static var previews: some View {
        SizeNotificationView(oldBytes: 750_190, newBytes: 211_932)
            .padding()
            .background(LinearGradient(colors: [.red, .orange, .blue], startPoint: .topLeading, endPoint: .bottomTrailing))
    }
}
