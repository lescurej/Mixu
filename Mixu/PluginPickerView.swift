//
//  PluginPickerView.swift
//  Mixu
//
//  Created by Johan Lescure on 29/09/2025.
//

import SwiftUI

struct PluginPickerView: View {
    let descriptors: [AudioPluginDescriptor]
    let onSelect: (AudioPluginDescriptor, Int) -> Void
    let onCancel: () -> Void
    
    @State private var channelCount = 2
    
    var body: some View {
        VStack {
            Stepper("Channels: \(channelCount)", value: $channelCount, in: 1...16)
                .padding()
            List(descriptors, id: \.name) { desc in
                Button(desc.name) {
                    onSelect(desc, channelCount)
                }
            }
            Button("Cancel", action: onCancel)
                .padding()
        }
        .frame(minWidth: 300, minHeight: 400)
    }
}
