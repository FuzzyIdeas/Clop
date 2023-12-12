//
//  Onboarding.swift
//  Clop
//
//  Created by Alin Panaitiu on 07.12.2023.
//

import Defaults
import Foundation
import SwiftUI

struct OnboardingView: View {
    var clopLogo: some View {
        ZStack(alignment: .topLeading) {
            Text("Clop")
                .font(.round(64, weight: .black))
            SwiftUI.Image("clop")
                .resizable()
                .scaledToFit()
                .frame(width: 64, height: 64)
                .offset(x: -10, y: -22)
                .rotationEffect(.degrees(-15))
        }
    }

    var menubar: some View {
        ZStack(alignment: .trailing) {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.gray.opacity(0.5), lineWidth: 1)
                .frame(height: 24)
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.primary.opacity(0.1))
                .frame(height: 24)
            HStack(spacing: 12) {
                SwiftUI.Image("MenubarIcon")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 21, height: 21)
                SwiftUI.Image(systemName: "wifi")
                Text("10:09")
            }
            .font(.regular(15))
            .padding(.trailing, 8)
        }
        .mask(LinearGradient(gradient: Gradient(colors: [.clear, .white]), startPoint: .leading, endPoint: .trailing))
    }

    var body: some View {
        ZStack {
            VStack {
                HStack {
                    clopLogo.padding()
                    VStack(alignment: .trailing) {
                        menubar
                        Text("""
                        Clop lives in your **menubar** and waits for you
                        to copy an image or **screenshot to clipboard**.
                        """)
                        .font(.round(14, weight: .regular))
                        Toggle(" Enable clipboard optimiser", isOn: $enableClipboardOptimiser)
                            .font(.round(11, weight: .regular))
                            .controlSize(.mini)
                    }
                }
                ZStack {
                    Color.bg.warm
                        .border(Color.black.opacity(colorScheme == .dark ? 0.4 : 0.1))
                        .scaleEffect(x: 1.3, y: 1.15)
                        .offset(y: 5)
                    HStack {
                        OnboardingFloatingPreview()
                            .offset(x: -40, y: 0)
                        Text("""
                        Optimised images will appear
                        as **floating thumbnails** in
                        the **corner of your screen**,
                        so you can further act on them.
                        """)
                    }
                    .padding(.vertical, -30)
                }

                Text("""
                Clop can also watch folders for new **images** and **videos**
                and **automatically** optimise them.
                """)
                .font(.round(14, weight: .regular))
                .padding()
                .multilineTextAlignment(.center)
                HStack {
                    VStack {
                        Text("Images").round(12)
                        DirListView(fileType: .image, dirs: $imageDirs, enabled: $enableAutomaticImageOptimisations, hideIgnoreRules: true)
                    }
                    VStack {
                        Text("Videos").round(12)
                        DirListView(fileType: .video, dirs: $videoDirs, enabled: $enableAutomaticVideoOptimisations, hideIgnoreRules: true)
                    }
                }
                Button("Start using Clop") {
                    (AppDelegate.instance as? AppDelegate)?.onboardingWindowController?.close()
                }
            }
            .padding()
            .blur(radius: min(0.6 - maskOpacity, 0.6) * 8)
            .mask(LinearGradient(stops: [
                .init(color: .white, location: maskOpacity + 0.1),
                .init(color: .clear, location: maskOpacity + 0.2),
            ], startPoint: .top, endPoint: .bottom))
            LinearGradient(
                gradient: Gradient(
                    colors: [.bg.warm.opacity(min(0.3 - maskOpacity, 0.3)), .bg.warm.opacity(1 - maskOpacity)]
                ),
                startPoint: .init(x: 0, y: -1),
                endPoint: .center
            )
            .scaleEffect(1.5)
            .allowsHitTesting(false)
        }
        .fixedSize()
        .focusable(false)
        .onAppear {
            withAnimation(.linear(duration: 2.5)) {
                maskOpacity = 1
            }
        }
    }

    @State private var maskOpacity = 0.0

    @Environment(\.colorScheme) private var colorScheme
    @Default(.enableClipboardOptimiser) private var enableClipboardOptimiser
    @Default(.imageDirs) private var imageDirs
    @Default(.videoDirs) private var videoDirs
    @Default(.enableAutomaticImageOptimisations) var enableAutomaticImageOptimisations
    @Default(.enableAutomaticVideoOptimisations) var enableAutomaticVideoOptimisations
}

#Preview {
    OnboardingView()
}
