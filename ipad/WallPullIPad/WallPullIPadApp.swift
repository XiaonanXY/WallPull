import SwiftUI

@main
struct WallPullIPadApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var vault: LocalVaultStore
    @StateObject private var localSend: LocalSendService
    @StateObject private var musicPlayer: MusicPlayerManager

    init() {
        let store = LocalVaultStore()
        _vault = StateObject(wrappedValue: store)
        _localSend = StateObject(wrappedValue: LocalSendService(vault: store))
        _musicPlayer = StateObject(wrappedValue: MusicPlayerManager())
    }

    var body: some Scene {
        WindowGroup {
            VaultGalleryView(vault: vault, localSend: localSend, musicPlayer: musicPlayer)
                .tint(vault.accentColor)
                .onAppear {
                    let mp = musicPlayer
                    vault.onItemsDeleted = { deletedIDs in
                        mp.handleDeletedItems(deletedIDs)
                    }
                    localSend.start()
                }
                .onChange(of: scenePhase) { phase in
                    if phase == .active {
                        localSend.handleAppDidBecomeActive()
                    }
                }
        }
    }
}
