//
//  ContentView.swift
//  Privacy Blinds
//
//  Test harness for the PrivacyBlinds package. Two independent `.privacyBlinds` overlays — a small
//  "Account" field and the scrolling notes below it — sit under a clean monochrome control panel
//  (on top, never covered) that lets you pick the cover (black / color / image from the library)
//  and shows whether the lens is currently revealed or covered as you roll the device.
//

import SwiftUI
import PhotosUI
import UIKit
import PrivacyBlinds

enum DemoCover: String, CaseIterable, Identifiable {
    case black = "Black"
    case color = "Color"
    case image = "Image"
    var id: String { rawValue }
}

struct ContentView: View {
    @State private var selectedCover: DemoCover = .black
    @State private var lensClosed = false
    @State private var photoItem: PhotosPickerItem?
    @State private var pickedImage: Image?
    @State private var maskOn = false
    @State private var authGazeOn = false
    @State private var ambientLux: Double = -1

    /// Resolve the segmented selection into the package's `PrivacyCover`. If "Image" is selected
    /// but nothing has been picked yet, fall back to black.
    private var currentCover: PrivacyCover {
        switch selectedCover {
        case .black: return .black
        case .color: return .color(Color(white: 0.5))
        case .image: return pickedImage.map { PrivacyCover.image($0) } ?? .black
        }
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            Color.white.ignoresSafeArea()

            VStack(alignment: .leading, spacing: 20) {
                // "Account: <number>" — only the NUMBER carries the privacy overlay.
                accountField

                // "Private Notes" title stays uncovered; the scroll below it carries the overlay.
                VStack(alignment: .leading, spacing: 8) {
                    Text("Private Notes")
                        .font(.largeTitle.weight(.bold))
                        .foregroundStyle(.black)

                    SecretContent()
                        .privacyBlinds(
                            cover: currentCover,
                            maskFillRatio: maskOn ? 0.4 : 0,
                            maskCellSize: 3,
                            authenticatedGaze: authGazeOn,
                            syncGroup: "account",   // unlock together with the account field (when gaze on)
                            onStateChange: { closed in lensClosed = closed },
                            onAmbientLux: { ambientLux = $0 }
                        )
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(20)

            // Control panel — floats on top, never covered.
            controlPanel
                .padding()
        }
        .tint(.primary)
        .preferredColorScheme(.light)
        .onChange(of: photoItem) { _, newItem in
            guard let newItem else { return }
            Task {
                if let data = try? await newItem.loadTransferable(type: Data.self),
                   let uiImage = UIImage(data: data) {
                    pickedImage = Image(uiImage: uiImage)
                    selectedCover = .image
                }
            }
        }
    }

    private var controlPanel: some View {
        VStack(spacing: 16) {
            HStack {
                Image(systemName: lensClosed ? "eye.slash" : "eye")
                    .font(.system(size: 16, weight: .medium))
                    .frame(width: 22, height: 22) // fixed box so eye/eye.slash don't change row height
                Text(lensClosed ? "Covered" : "Revealed")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                PhotosPicker(selection: $photoItem, matching: .images) {
                    Label("Choose Image", systemImage: "photo")
                        .font(.subheadline.weight(.medium))
                }
            }
            .foregroundStyle(.black)

            Picker("Cover", selection: $selectedCover) {
                ForEach(DemoCover.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)

            Toggle("Privacy mask", isOn: $maskOn)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.black)

            Toggle("Authenticated gaze (Face ID)", isOn: $authGazeOn)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.black)

            if authGazeOn {
                Text("Ambient: \(ambientLux < 0 ? "—" : String(Int(ambientLux))) lux")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.black.opacity(0.6))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(20)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(.white)
                .stroke(.black.opacity(0.1), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.08), radius: 16, y: 4)
    }

    /// "Account: 4029 8175" on a single line. Only the number carries the privacy overlay (always Face
    /// ID, no lock icon); the "Account:" label stays visible. (Made-up 8-digit number.)
    private var accountField: some View {
        let number = "4029 8175"
        return HStack(spacing: 6) {
            Text("Account:")
                .font(.body.weight(.semibold))
                .foregroundStyle(.black)
            // The secure-capture host fills its frame, so pin the protected number to one line: a hidden
            // ruler copy sets the height, and the real (protected) number fills that exact one-line box —
            // screenshot protection stays on (default), so the number is excluded from captures too.
            Text(number)
                .font(.body.monospacedDigit())
                .frame(maxWidth: .infinity, alignment: .leading)
                .hidden()
                .overlay {
                    Text(number)
                        .font(.body.monospacedDigit())
                        .foregroundStyle(.black)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .privacyBlinds(
                            authenticatedGaze: true,
                            syncGroup: "account",   // one Face ID unlocks this + the notes (when gaze on)
                            showsLockIcon: false
                        )
                }
        }
    }
}

/// Mock secret content — the scrolling notes only (the "Private Notes" title lives above this in the
/// caller). Text-heavy so reveal/cover reads clearly; hairline dividers between entries. The caller
/// wraps this in its own `.privacyBlinds` overlay.
struct SecretContent: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(0..<12) { i in
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Entry \(i + 1)")
                            .font(.headline)
                            .foregroundStyle(.black)
                        Text("The quick brown fox jumps over the lazy dog. "
                             + "Sensitive details you only want visible while reading.")
                            .font(.subheadline)
                            .foregroundStyle(.black.opacity(0.55))
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 18)

                    if i < 11 { Divider().overlay(.black.opacity(0.08)) }
                }
            }
            .padding(.bottom, 220) // keep last rows clear of the control panel
        }
    }
}

#Preview {
    ContentView()
}
