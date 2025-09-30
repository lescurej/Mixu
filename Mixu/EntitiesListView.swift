//
//  EntitiesListView.swift
//  Mixu
//
//  Created by Johan Lescure on 29/09/2025.
//

import SwiftUI

struct EntitiesListView: View {
    @ObservedObject var engine: RouterEngine
    
    @State private var inputs: [AudioDevice] = []
    @State private var passthru: [AudioDevice] = []
    @State private var outputs: [AudioDevice] = []
    @State private var plugins: [AudioPluginDescriptor] = []
    
    @State private var multiSelection = Set<UUID>()

        var body: some View {
            VStack {
                showAudioDeviceCategory("INPUTS", devices: inputs)
                showAudioDeviceCategory("PASS THRU", devices: passthru)
                showAudioDeviceCategory("OUTPUTS", devices: outputs)
                showPluginsCategory("PLUG-INS", devices: plugins)
            }
            .onAppear(perform: {
                inputs = engine.availableInputs()
                let passthruDev = engine.passThruDevice()
                if passthruDev != nil {
                    passthru = []
                    passthru.append(passthruDev!)
                }
                outputs = engine.availableOutputs()
                plugins = engine.availableAudioUnitEffects()
            })
        }
    
    private func showAudioDeviceCategory(_ category: String, devices: [AudioDevice]) -> some View {
        VStack{
           
                 List(devices, id: \.name, selection: $multiSelection) { d in
                     Text(d.name)
                 }
                 .toolbarVisibility(.visible)
                 .toolbarTitleMenu {
                    Text(category)
                 }
                 .listStyle(.sidebar)
                 .navigationTitle(category)
                 .toolbarTitleDisplayMode(.inline)
                 
            }
     
    }
    
    private func showPluginsCategory(_ category: String, devices: [AudioPluginDescriptor]) -> some View {
        VStack{
            Text(category)
            List(devices, id: \.name, selection: $multiSelection) { d in
                Text(d.name)
            }
            //.toolbar { EditButton() }
            Divider()
        }
    }
}

#Preview {
    EntitiesListView(engine: MockRouterEngine())
    .frame(width: 200, height: 800)

}
