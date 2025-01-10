//
//  Onboarding.swift
//  Clop
//
//  Created by Alin Panaitiu on 07.12.2023.
//

import Defaults
import Foundation
import Lowtech
import SwiftUI

struct DropZoneDemoAnimationView: View {
    @Binding var dropped: Bool

    var image: some View {
        VStack(spacing: 10) {
            SwiftUI.Image(nsImage: NSImage(resource: .sonomaShot))
                .resizable()
                .background(
                    Rectangle()
                        .fill(Color.white)
                        .scaleEffect(x: 1.15, y: 1.2)
                        .shadow(radius: 8)
                )
                .scaledToFill()
                .frame(width: 70, height: 50)
            Text("screenshot.png")
                .font(.round(12))
                .foregroundColor(clicked ? .white : .primary)
                .background(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(Color.blue.opacity(clicked ? 1.0 : 0.0))
                        .scaleEffect(1.1)
                )
        }
    }
    var imageFileWithCursor: some View {
        ZStack {
            image
                .scaleEffect(letGo ? 0.0 : (clicked ? 1.05 : 1.0))
            SwiftUI.Image(systemName: clicked ? "cursorarrow.rays" : "cursorarrow")
                .foregroundColor(.black)
                .font(.system(size: clicked ? 32 : 24, weight: .bold))
                .offset(x: 10, y: 0)
        }
    }
    var body: some View {
        VStack {
            HStack(spacing: 100) {
                ZStack {
                    image.offset(Self.INITIAL_OFFSET)
                    imageFileWithCursor.offset(draggedFileOffset)
                }
                DropZoneView(blurredBackground: false).padding(.horizontal, -20)
            }
            Text("Drag files into the **drop zone** at\nthe **bottom right** corner of your screen")
                .multilineTextAlignment(.center)
        }
        .onAppear {
            mainAsyncAfter(ms: 1000) {
                withAnimation(.snappy(duration: 0.2)) {
                    clicked = true
                }
                mainAsyncAfter(ms: 300) {
                    withAnimation(.smooth(duration: 0.7)) {
                        draggedFileOffset = CGSize(width: 310, height: 10)
                    }
                }
                mainAsyncAfter(ms: 700) {
                    withAnimation(.jumpySpring) {
                        dragManager.dragHovering = true
                    }
                }
                mainAsyncAfter(ms: 1300) {
                    withAnimation(.smooth(duration: 0.2)) {
                        letGo = true
                        clicked = false
                    }
                }
                mainAsyncAfter(ms: 2000) {
                    withAnimation(.easeOut) {
                        dropped = true
                        dragManager.dragHovering = false
                    }
                }
            }
        }
    }

    private static var INITIAL_OFFSET = CGSize(width: 0, height: -30)

    @State private var draggedFileOffset = INITIAL_OFFSET
    @State private var clicked = false
    @State private var letGo = false
    @ObservedObject private var dragManager = DM

}
struct OnboardingView: View {
    @ObservedObject var bm = BM
    @State private var fileDropped = true

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

                    if fileDropped {
                        VStack {
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
                            Button("Replay") {
                                fileDropped = false
                            }
                        }
                        .frame(width: 530, height: 200)
                    } else {
                        DropZoneDemoAnimationView(dropped: $fileDropped)
                            .frame(width: 530, height: 200)
                    }
                }
                .padding(.bottom, 20)

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
                .padding(.bottom, 20)

                if bm.decompressingBinaries {
                    ProgressView("Preparing optimisers...")
                        .progressViewStyle(.linear)
                        .padding()
                } else {
                    Button("Start using Clop") {
                        (AppDelegate.instance as? AppDelegate)?.onboardingWindowController?.close()
                    }
                    .font(.round(14, weight: .semibold))
                    .foregroundColor(.primary.opacity(0.9))
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
            mainAsyncAfter(ms: 5000) {
                fileDropped = false
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
