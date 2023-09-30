import Foundation
import Lowtech
import SwiftUI

struct FileNameField: View {
    @ObservedObject var optimiser: Optimiser
    @FocusState var focused: Bool
    @State var tempName = ""
    @Namespace var namespace

    @ViewBuilder var viewer: some View {
        let ext = optimiser.url?.filePath.extension ?? optimiser.originalURL?.filePath.extension ?? ""
        HStack {
            (Text(tempName) + Text(".\(ext)").fontDesign(.monospaced))
                .hfill(.leading)
                .frame(height: 16)
                .lineLimit(1)
                .truncationMode(.tail)
                .matchedGeometryEffect(id: "filename", in: namespace)

            if !optimiser.running {
                Button(action: {
                    withAnimation(.easeOut(duration: 0.1)) { optimiser.editingFilename = true }
                    focus()
                }, label: { SwiftUI.Image(systemName: "pencil").foregroundColor(.primary) })
                    .buttonStyle(FlatButton(color: .clear, textColor: .white, horizontalPadding: 0, verticalPadding: 0))
                    .fontWeight(.bold)
                    .frame(width: 18)
                    .contentShape(Rectangle())
                    .focusable(false)
                    .matchedGeometryEffect(id: "button", in: namespace)
            }
        }
    }

    var editor: some View {
        HStack {
            TextField("", text: $tempName)
                .textFieldStyle(PlainTextFieldStyle())
                .hfill(.leading)
                .frame(height: 16)
                .onSubmit {
                    optimiser.rename(to: tempName)
                    optimiser.editingFilename = false
                }
                .focused($focused)
                .defaultFocus($focused, true)
                .onAppear {
                    focused = true
                    sizeNotificationWindow.allowToBecomeKey = true
                    focus()
                    sizeNotificationWindow.becomeFirstResponder()
                    sizeNotificationWindow.makeKeyAndOrderFront(nil)
                    sizeNotificationWindow.orderFrontRegardless()
                }
                .matchedGeometryEffect(id: "filename", in: namespace)

            Button(action: {
                optimiser.editingFilename = false
            }, label: { SwiftUI.Image(systemName: "xmark").foregroundColor(.primary) })
                .buttonStyle(FlatButton(color: .clear, textColor: .white, horizontalPadding: 0, verticalPadding: 0))
                .fontWeight(.bold)
                .frame(width: 18)
                .contentShape(Rectangle())
                .keyboardShortcut(.escape, modifiers: [])
                .matchedGeometryEffect(id: "button", in: namespace)
        }
    }

    @ViewBuilder var editorViewer: some View {
        if optimiser.editingFilename {
            editor
        } else {
            viewer
                .onAppear {
                    tempName = optimiser.url?.filePath.stem ?? optimiser.originalURL?.filePath.stem ?? "filename"
                }
                .onChange(of: optimiser.url) { url in
                    tempName = url?.filePath.stem ?? "filename"
                }
        }
    }

    var body: some View {
        editorViewer
            .onChange(of: optimiser.running) { running in
                if running {
                    optimiser.editingFilename = false
                }
            }
    }
}

var editingSetter: DispatchWorkItem? {
    didSet {
        oldValue?.cancel()
    }
}
