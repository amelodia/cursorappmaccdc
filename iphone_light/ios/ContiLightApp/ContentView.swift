import SwiftUI
import UIKit
import UniformTypeIdentifiers

// MARK: - Bookmark cartella (Files / Dropbox)

private enum ContiLightFolderBookmark {
    /// Persistenza come l’app Document-based: dati bookmark in `UserDefaults` (restano dopo chiusura app).
    private static let key = "ContiLight.dataFolderSecurityBookmark"

    static func save(_ url: URL) {
        // Su iOS: minimalBookmark + metadati riduce bookmark «stale» dopo riavvio; niente withSecurityScope (solo macOS).
        guard let data = try? url.bookmarkData(
            options: .minimalBookmark,
            includingResourceValuesForKeys: [.isDirectoryKey],
            relativeTo: nil
        ) else { return }
        UserDefaults.standard.set(data, forKey: Self.key)
    }

    /// Rinnova il bookmark mentre l’accesso security-scoped è attivo (consigliato da Apple se `bookmarkDataIsStale`).
    static func renew(from url: URL) {
        save(url)
    }

    static func restore() -> URL? {
        guard let data = UserDefaults.standard.data(forKey: Self.key) else { return nil }
        var stale = false
        guard let url = try? URL(
            resolvingBookmarkData: data,
            options: [.withoutUI],
            relativeTo: nil,
            bookmarkDataIsStale: &stale
        ) else {
            UserDefaults.standard.removeObject(forKey: Self.key)
            return nil
        }
        if stale {
            UserDefaults.standard.removeObject(forKey: Self.key)
            return nil
        }
        return url
    }

    static func clear() {
        UserDefaults.standard.removeObject(forKey: Self.key)
    }
}

// MARK: - Ultima email (prefill schermata accesso)

private enum ContiLightLastLoginEmail {
    private static let key = "ContiLight.lastLoginEmail"

    static func save(_ value: String) {
        let t = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty {
            UserDefaults.standard.removeObject(forKey: key)
        } else {
            UserDefaults.standard.set(t, forKey: key)
        }
    }

    static func load() -> String {
        (UserDefaults.standard.string(forKey: key) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

@MainActor
struct ContentView: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.scenePhase) private var scenePhase

    /// Cartella che contiene `.key` e i `.enc` (stessa cartella `data/` del desktop).
    @State private var dataFolderURL: URL?
    @State private var keyStatusText = ""
    @State private var lightFileStatusText = ""
    @State private var fullFileStatusText = ""
    @State private var email = ""
    @State private var password = ""
    /// Messaggi da login / scelta cartella; se vuoto si mostra `loginFootnoteText`.
    @State private var message = ""
    @State private var isBusy = false
    @State private var isRefreshingSession = false
    @State private var loggedInRecords: [ContiRecordRow] = []
    /// DB sessione per saldi, immissioni e salvataggio; bridging `NSDictionary` dal thread di login.
    @State private var loggedInSessionDb: NSDictionary?
    /// Percorsi risolti all’ultimo accesso riuscito (scrittura `.enc` dopo nuove registrazioni).
    @State private var sessionKeyURL: URL?
    @State private var sessionLightEncURL: URL?
    @State private var movimentiDisplayName = ""
    @State private var movimentiPath = NavigationPath()
    @State private var showFiltriSheet = false
    /// `""` = tutte le categorie / tutti i conti.
    @State private var filterCategoryKey = ""
    @State private var filterAccountKey = ""
    @State private var folderPickRequest: FolderPickRequest?
    /// File `*_light.enc` scelto nel selettore: quella URL è un download nuovo, non la copia in cache della cartella.
    @State private var pickedLightEncURL: URL?
    @State private var lightFilePickRequest: FolderPickRequest?
    /// Navigazione interna alla sheet Filtri (tap → lista, senza NavigationLink lento).
    @State private var filtriNavigationPath = NavigationPath()
    /// Elenco movimenti: per data o per numero di registrazione (globale).
    @State private var movimentiListSort: ContiMovimentiListSort = .dateNewestFirst
    /// Se attivo, dopo un accesso con password riuscito la password viene salvata nel Keychain per Face ID / Touch ID.
    @AppStorage("ContiLight.savePasswordForBiometrics") private var savePasswordForBiometrics = false
    /// Messaggio lungo (come più ``showinfo`` sul desktop) dopo materializzazione periodiche.
    @State private var periodicStartupAlertText = ""
    @State private var periodicStartupAlertPresented = false
    /// Throttle per ``refreshLightSessionIfLoggedIn`` (solo lettura + decifra; non riscrive `.enc`). Evita hammer al provider file.
    @State private var lastScenePhaseRefreshAt: Date = .distantPast
    /// Se l’app va in background a metà salvataggio, chiudi la sessione solo a scrittura completata.
    @State private var closeSessionWhenPersistEnds = false
    /// Registrazioni tenute in memoria: un solo aggiornamento di ``*_light.enc`` all’uscita, non uno per riga.
    @State private var lightDropboxDirty = false
    @State private var lanKeyText = ""
    @State private var lanDidClearPending = false
    @State private var lanMacClosedNoticeShown = false
    /// Evict + riscaricamento `*_light.enc` da Dropbox/Files (login e tasto Allinea).
    @State private var isAligningCloud = false
    /// Codice del primo accoppiamento. Dopo, il telefono rientra da solo.
    @State private var provaCode = ""
    @State private var provaLanActive = false
    @State private var lanFingerprints: [String: String] = [:]
    @State private var lanClient = ContiLanClient()
    @State private var lanTokenKnown = false
    @State private var lanNoticeText = ""
    @State private var lanNoticePresented = false

    private enum MovimentiFiltriPick: Hashable {
        case category
        case account
    }

    var body: some View {
        NavigationStack(path: $movimentiPath) {
            Group {
                if loggedInSessionDb == nil {
                    loginForm
                } else {
                    recordsList
                }
            }
            .navigationDestination(for: MovimentiSchedaRoute.self) { route in
                switch route {
                case .saldi:
                    ContiLightSaldiSchedaView(sessionDb: loggedInSessionDb)
                case .nuoviDati:
                    ContiLightNuovoMovimentoSchedaView(
                        sessionDb: loggedInSessionDb as? [String: Any],
                        dataFolderURL: dataFolderURL,
                        keyURL: sessionKeyURL,
                        lightEncURL: sessionLightEncURL,
                        savesOverLan: provaLanActive,
                        email: email,
                        password: password,
                        onPersisted: { updatedDb, _, note in
                            rememberSessionForDropboxFlush(updatedDb, note: note)
                        }
                    )
                case .modifica(let legacyKey):
                    ContiLightNuovoMovimentoSchedaView(
                        sessionDb: loggedInSessionDb as? [String: Any],
                        dataFolderURL: dataFolderURL,
                        keyURL: sessionKeyURL,
                        lightEncURL: sessionLightEncURL,
                        savesOverLan: provaLanActive,
                        email: email,
                        password: password,
                        onPersisted: { updatedDb, _, note in
                            rememberSessionForDropboxFlush(updatedDb, note: note)
                        },
                        editingLegacyKey: legacyKey
                    )
                }
            }
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .onChange(of: loggedInSessionDb == nil) { _, noSession in
            if noSession {
                movimentiPath = NavigationPath()
                sessionKeyURL = nil
                sessionLightEncURL = nil
                applySavedLoginEmailIfNeeded()
            }
        }
        .onAppear {
            if dataFolderURL == nil, let restored = ContiLightFolderBookmark.restore() {
                let access = restored.startAccessingSecurityScopedResource()
                let reject = access ? ContiDatabase.rejectReasonIfNotDesktopDataFolder(restored) : nil
                if access { restored.stopAccessingSecurityScopedResource() }
                if let reject {
                    ContiLightFolderBookmark.clear()
                    message = reject
                } else {
                    dataFolderURL = restored
                }
            }
            applySavedLoginEmailIfNeeded()
            refreshKeyStatus()
            Task { lanTokenKnown = await lanClient.hasSavedToken() }
        }
        .task(id: provaLanActive) {
            guard provaLanActive else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(4))
                guard !Task.isCancelled, provaLanActive else { continue }
                await pollLanRevision()
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if provaLanActive {
                if phase == .active {
                    closeSessionWhenPersistEnds = false
                    Task { @MainActor in
                        await refreshLanIfLoggedIn(quiet: true)
                    }
                } else if phase == .background {
                    Task { @MainActor in
                        await flushLanIfDirty()
                    }
                }
                return
            }
            if phase == .active, dataFolderURL != nil {
                closeSessionWhenPersistEnds = false
                refreshKeyStatus()
                // Rilegge il `*_light.enc` con path risolto di nuovo e attesa Dropbox (come «Aggiorna»), così dopo sync non resta la copia precedente in memoria.
                Task { @MainActor in
                    if Date().timeIntervalSince(lastScenePhaseRefreshAt) >= 3 {
                        await refreshLightSessionIfLoggedIn()
                    }
                }
            } else if phase == .background {
                // Una sola scrittura Dropbox per tutte le registrazioni della sessione, poi chiusura.
                closeSessionWhenPersistEnds = true
                Task { @MainActor in
                    await flushLightSessionToDropboxIfDirty()
                    while ContiDatabase.isPersistInProgress {
                        try? await Task.sleep(nanoseconds: 200_000_000)
                    }
                    if closeSessionWhenPersistEnds {
                        closeSessionWhenPersistEnds = false
                        closeCurrentSessionAndReleaseLock()
                    }
                }
            }
        }
        .onChange(of: email) { _, _ in
            if dataFolderURL != nil {
                refreshKeyStatus()
            }
        }
        .onChange(of: savePasswordForBiometrics) { _, enabled in
            if !enabled {
                ContiLightBiometricLogin.deleteAllBiometricCredentials()
            }
        }
        .onChange(of: showFiltriSheet) { _, open in
            if !open {
                filtriNavigationPath = NavigationPath()
            }
        }
        .onChange(of: movimentiListSort) { _, _ in
            guard let d = loggedInSessionDb as? [String: Any] else { return }
            loggedInRecords = ContiDatabase.displayRecords(from: d, sort: movimentiListSort)
        }
        .alert("Registrazioni periodiche", isPresented: $periodicStartupAlertPresented) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(periodicStartupAlertText)
        }
        .alert("Sincronizzazione", isPresented: $lanNoticePresented) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(lanNoticeText)
        }
    }

    /// Se `EuroBrand` non è nel target, mostra un’icona SF Symbol (evita build/runtime fragili).
    @ViewBuilder
    private var loginBrandMark: some View {
        if UIImage(named: "EuroBrand") != nil {
            Image("EuroBrand")
                .resizable()
                .scaledToFit()
                .frame(width: 72, height: 72)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .accessibilityLabel("Simbolo euro")
        } else {
            Image(systemName: "eurosign.circle.fill")
                .font(.system(size: 56))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.secondary)
                .accessibilityLabel("Simbolo euro")
        }
    }

    private var loginFootnoteText: String {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return message }
        if !lanTokenKnown {
            return "Al primo collegamento inserisci email, password e il codice di 6 cifre mostrato da Conti di casa sul Mac, acceso sulla stessa rete Wi-Fi."
        }
        return "Inserisci email e password. Conti Light si collega al Mac acceso sulla stessa rete Wi-Fi."
    }

    private var loginForm: some View {
        Form {
            Section {
                VStack(spacing: 12) {
                    loginBrandMark
                    Text("Conti di casa — accesso al database cifrato")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 4)
            }
            Section("Accesso") {
                TextField("Email", text: $email)
                    .textContentType(.emailAddress)
                    .textInputAutocapitalization(.never)
                    .keyboardType(.emailAddress)
                    .submitLabel(.next)
                SecureField("Password", text: $password)
                    .submitLabel(.go)
                    .onSubmit { loginWithProvaLan() }
                if ContiLightBiometricLogin.biometricsAvailable() {
                    Toggle(
                        "Salva password per \(ContiLightBiometricLogin.biometricLabel())",
                        isOn: $savePasswordForBiometrics
                    )
                    .font(.subheadline)
                }
                if ContiLightBiometricLogin.isConfigured(forEmail: email) {
                    Button(action: loginWithBiometrics) {
                        HStack {
                            if isBusy {
                                ProgressView()
                            }
                            Label(
                                "Accedi con \(ContiLightBiometricLogin.biometricLabel())",
                                systemImage: ContiLightBiometricLogin.biometricSystemImageName()
                            )
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .disabled(isBusy || isAligningCloud)
                }
                Button(action: { loginWithProvaLan() }) {
                    HStack {
                        if isBusy {
                            ProgressView()
                        }
                        Text(isBusy ? "Accesso…" : "Accedi")
                    }
                    .frame(maxWidth: .infinity)
                }
                .disabled(
                    isBusy || isAligningCloud || email.isEmpty || password.isEmpty
                        || (provaCode.count != 6 && !lanTokenKnown)
                )
                if !lanTokenKnown {
                    TextField("Codice di 6 cifre", text: $provaCode)
                        .keyboardType(.numberPad)
                }
                if lanTokenKnown {
                    Button("Dimentica l'accoppiamento") {
                        Task {
                            await lanClient.forgetPairing()
                            lanTokenKnown = false
                        }
                    }
                }
            }
            Section {
                Text(loginFootnoteText)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.visible)
        .navigationTitle("Conti di casa")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $lightFilePickRequest) { _ in
            DocumentFilePickerRepresentable(
                onPick: { url in
                    Task { @MainActor in
                        lightFilePickRequest = nil
                        let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
                        let name = url.lastPathComponent
                        guard !isDirectory, name.lowercased().hasSuffix(".enc"), name.lowercased().contains("light") else {
                            message = "Seleziona il file *_light.enc (non la cartella e non il database completo)."
                            return
                        }
                        if let previous = pickedLightEncURL {
                            previous.stopAccessingSecurityScopedResource()
                        }
                        guard url.startAccessingSecurityScopedResource() else {
                            message = "Accesso al file negato. Riprova dal selettore."
                            return
                        }
                        let parent = url.deletingLastPathComponent()
                        guard ContiDatabase.folderLooksLikeDesktopDataFolder(parent) else {
                            url.stopAccessingSecurityScopedResource()
                            message = """
                            «\(name)» non è nella cartella dati. \
                            Apri Dropbox → ContiCursor e scegli il *_light.enc accanto a conti_di_casa.key.
                            """
                            return
                        }
                        if parent.standardizedFileURL.path != dataFolderURL?.standardizedFileURL.path {
                            ContiLightFolderBookmark.save(parent)
                            dataFolderURL = parent
                            refreshKeyStatus()
                        }
                        pickedLightEncURL = url
                        message = "File scelto: \(name), cartella «\(parent.lastPathComponent)». Tocca Accedi."
                    }
                },
                onCancel: {
                    Task { @MainActor in
                        lightFilePickRequest = nil
                    }
                }
            )
            .ignoresSafeArea()
        }
        .sheet(item: $folderPickRequest) { _ in
            DocumentFolderPickerRepresentable(
                onPick: { url in
                    Task { @MainActor in
                        folderPickRequest = nil
                        let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
                        guard isDirectory else {
                            message = """
                            Hai selezionato un file, non una cartella. Nel selettore: Sfoglia → Dropbox → ContiCursor, \
                            poi «Apri» sulla cartella — non sul file .key o .enc. Non usare la cartella ContiLight.
                            """
                            return
                        }
                        ContiLightFolderBookmark.save(url)
                        dataFolderURL = url
                        refreshKeyStatus()
                        let name = url.lastPathComponent
                        if name.compare("ContiLight", options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame {
                            message = """
                            Hai aperto la cartella ContiLight (progetto Xcode). I file dati non sono lì. \
                            Tocca di nuovo «Cambia cartella…» e apri Dropbox → ContiCursor.
                            """
                        } else {
                            message = "Cartella «\(name)» impostata. Inserisci email e password, poi Accedi."
                        }
                    }
                },
                onCancel: {
                    Task { @MainActor in
                        folderPickRequest = nil
                    }
                }
            )
            .ignoresSafeArea()
        }
    }

    private func refreshKeyStatus() {
        guard let folder = dataFolderURL else {
            keyStatusText = ""
            lightFileStatusText = ""
            fullFileStatusText = ""
            return
        }
        guard folder.startAccessingSecurityScopedResource() else {
            keyStatusText = "Accesso alla cartella negato."
            lightFileStatusText = ""
            fullFileStatusText = ""
            return
        }
        defer { folder.stopAccessingSecurityScopedResource() }
        (folder as NSURL).removeAllCachedResourceValues()
        if let k = ContiDatabase.preferredKeyFileURL(inFolder: folder) {
            keyStatusText = "Chiave: \(k.lastPathComponent)"
        } else {
            keyStatusText = "Nessun file .key trovato (es. conti_di_casa.key nella cartella dati)."
        }
        let em = email.trimmingCharacters(in: .whitespacesAndNewlines)
        if let light = ContiDatabase.resolvePrimaryEncURL(inFolder: folder, email: em) {
            lightFileStatusText = cloudFileStatusLine(prefix: "File light", url: light)
        } else {
            let stem = ContiDatabase.userEncFilenameStem(forEmail: em)
            lightFileStatusText = "File light non trovato (atteso: \(stem)_light.enc nella cartella)."
        }
        let conflicted = ContiDatabase.dropboxConflictedEncFilenames(inFolder: folder)
        if !conflicted.isEmpty {
            let n = conflicted.count
            let line = n == 1
                ? "1 copia in conflitto è visibile solo nella cache dell’app File: non è su Dropbox e non viene aperta."
                : "\(n) copie in conflitto sono visibili solo nella cache dell’app File: non sono su Dropbox e non vengono aperte."
            lightFileStatusText += "\n" + line
        }
        if !em.isEmpty {
            let stemName = ContiDatabase.userEncFilenameStem(forEmail: em)
            let full = folder.appendingPathComponent("\(stemName).enc", isDirectory: false)
            if FileManager.default.fileExists(atPath: full.path) {
                fullFileStatusText = cloudFileStatusLine(prefix: "File completo", url: full)
            } else {
                fullFileStatusText = "File completo non trovato per questa email (\(full.lastPathComponent))."
            }
        } else {
            fullFileStatusText = "File completo: inserisci email per verificare il percorso dedicato."
        }
        // Aggiorna il bookmark su disco: evita che al prossimo avvio iOS lo consideri obsoleto e «perda» la cartella.
        ContiLightFolderBookmark.renew(from: folder)
    }

    private func cloudFileStatusLine(prefix: String, url: URL) -> String {
        (url as NSURL).removeAllCachedResourceValues()
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        let mtime = attrs?[.modificationDate] as? Date
        let size = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
        var parts: [String] = ["\(prefix): \(url.lastPathComponent)"]
        if let d = mtime {
            let f = DateFormatter()
            f.locale = Locale(identifier: "it_IT")
            f.timeZone = .current
            f.dateFormat = "dd/MM/yyyy HH:mm:ss"
            parts.append("aggiornato: \(f.string(from: d))")
        }
        if size > 0 {
            let fmt = ByteCountFormatter()
            fmt.allowedUnits = [.useKB, .useMB]
            fmt.countStyle = .file
            parts.append(fmt.string(fromByteCount: size))
        }
        return parts.joined(separator: " — ")
    }

    /// Scarta la copia File Provider dell’ultimo accesso e riscarica `*_light.enc` da Dropbox.
    private func alignLightFileFromCloud() async {
        guard let folder = dataFolderURL else { return }
        guard !isBusy, !isAligningCloud else { return }
        isAligningCloud = true
        message = "Richiesta copia aggiornata a Dropbox…"
        let emailTrim = email.trimmingCharacters(in: .whitespacesAndNewlines)
        let folderURL = folder
        let result: String = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let access = folderURL.startAccessingSecurityScopedResource()
                defer {
                    if access {
                        folderURL.stopAccessingSecurityScopedResource()
                    }
                }
                guard access else {
                    continuation.resume(
                        returning: "Impossibile accedere alla cartella (permessi). Usa «Cambia cartella…» e riselezionala."
                    )
                    return
                }
                continuation.resume(
                    returning: ContiDatabase.realignLightEncFilesFromCloud(in: folderURL, email: emailTrim)
                )
            }
        }
        refreshKeyStatus()
        message = result
        isAligningCloud = false
    }

    /// Categorie distinte (testo mostrato in lista), ordinate.
    private var movimentiCategoryChoices: [String] {
        let s = Set(loggedInRecords.map(\.categoryDisplay).filter { !$0.isEmpty })
        return s.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    /// Nomi conto (principale o secondario) presenti nei movimenti, ordinati.
    private var movimentiAccountChoices: [String] {
        var s = Set<String>()
        for r in loggedInRecords {
            if !r.accountPrimary.isEmpty { s.insert(r.accountPrimary) }
            if !r.accountSecondary.isEmpty { s.insert(r.accountSecondary) }
        }
        return s.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    private var movimentiFiltersActive: Bool {
        activeCategoryFilter != nil || activeAccountFilter != nil
    }

    private var showMovimentiEditHint: Bool {
        !filteredMovimentiRecords.isEmpty
    }

    /// Filtro categoria effettivo (`nil` se disattivo o valore non più nella lista).
    private var activeCategoryFilter: String? {
        guard !filterCategoryKey.isEmpty, movimentiCategoryChoices.contains(filterCategoryKey) else { return nil }
        return filterCategoryKey
    }

    private var activeAccountFilter: String? {
        guard !filterAccountKey.isEmpty, movimentiAccountChoices.contains(filterAccountKey) else { return nil }
        return filterAccountKey
    }

    private var filteredMovimentiRecords: [ContiRecordRow] {
        loggedInRecords.filter { row in
            if let c = activeCategoryFilter, row.categoryDisplay != c { return false }
            if let a = activeAccountFilter {
                if row.accountPrimary != a, row.accountSecondary != a { return false }
            }
            return true
        }
    }

    @ViewBuilder
    private func movimentiListRowView(
        row: ContiRecordRow,
        rowPrimaryText: Color,
        amountColor: (Decimal) -> Color,
        accountLine: (ContiRecordRow) -> String
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(row.dateDisplay)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(rowPrimaryText)
                Spacer(minLength: 8)
                Text(row.categoryDisplay)
                    .font(.subheadline)
                    .foregroundStyle(.blue)
                    .multilineTextAlignment(.trailing)
            }
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(accountLine(row))
                    .font(.subheadline)
                    .foregroundStyle(rowPrimaryText)
                    .multilineTextAlignment(.leading)
                Spacer(minLength: 8)
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text("Importo €")
                        .font(.subheadline)
                        .foregroundStyle(Color.secondary)
                    if let v = row.amountValue {
                        Text(ContiDatabase.formatEuroTwoDecimals(v))
                            .font(.subheadline.monospacedDigit())
                            .foregroundStyle(amountColor(v))
                    } else {
                        Text(row.amountRawFallback)
                            .font(.subheadline.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
            }
            if !row.note.isEmpty, row.note != "-" {
                Text(row.note)
                    .font(.caption)
                    .foregroundStyle(rowPrimaryText.opacity(0.9))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.vertical, 4)
    }

    private func hapticMovimentiModifica() {
        let g = UIImpactFeedbackGenerator(style: .medium)
        g.prepare()
        g.impactOccurred()
    }

    @ViewBuilder
    private func movimentiRowConnect(row: ContiRecordRow) -> some View {
        if !row.legacyRegistrationKey.isEmpty {
            HStack(alignment: .top, spacing: 8) {
                movimentiListRowView(
                    row: row,
                    rowPrimaryText: rowPrimaryText,
                    amountColor: amountColor,
                    accountLine: accountLine
                )
                .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "hand.point.up.left.fill")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .padding(.top, 2)
                    .accessibilityHidden(true)
            }
            .contentShape(Rectangle())
            .onLongPressGesture(minimumDuration: 0.5) {
                hapticMovimentiModifica()
                movimentiPath.append(MovimentiSchedaRoute.modifica(legacyKey: row.legacyRegistrationKey))
            }
            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                Button {
                    hapticMovimentiModifica()
                    movimentiPath.append(MovimentiSchedaRoute.modifica(legacyKey: row.legacyRegistrationKey))
                } label: {
                    Label("Modifica", systemImage: "pencil")
                }
                .tint(.indigo)
            }
            .accessibilityElement(children: .combine)
            .accessibilityHint("Tieni premuto mezzo secondo sulla riga, oppure scorri verso sinistra e tocca Modifica, per modificare o annullare.")
        } else {
            movimentiListRowView(
                row: row,
                rowPrimaryText: rowPrimaryText,
                amountColor: amountColor,
                accountLine: accountLine
            )
        }
    }

    private var recordsList: some View {
        List {
            Section {
                if filteredMovimentiRecords.isEmpty {
                    ContentUnavailableView(
                        "Nessun risultato",
                        systemImage: "line.3.horizontal.decrease.circle",
                        description: Text("Prova altri criteri in Filtri o reimposta le selezioni.")
                    )
                    .frame(minHeight: 160)
                    Button("Filtri") { showFiltriSheet = true }
                    .frame(maxWidth: .infinity)
                } else {
                    ForEach(filteredMovimentiRecords) { row in
                        movimentiRowConnect(row: row)
                    }
                }
            } header: {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Conti di casa — \(movimentiDisplayName)")
                        .font(.headline)
                    Text(italianLongToday())
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    if showMovimentiEditHint {
                        Text(
                            "Tieni premuto su una riga (almeno ½ secondo) o scorri a sinistra → Modifica per correggere o annullare una registrazione (anche creata sul desktop). "
                        )
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    }
                    if let summary = movimentiFiltriSummaryLine {
                        Text(summary)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .textCase(nil)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 4)
            }
        }
        .listStyle(.insetGrouped)
        .refreshable {
            if provaLanActive {
                await refreshLanIfLoggedIn()
            } else {
                await refreshLightSessionIfLoggedIn(forceReResolveEnc: true, forceCloudRedownload: true)
            }
        }
        .navigationTitle("Movimenti")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button("Esci", role: .none) {
                    closeCurrentSessionAndReleaseLock()
                }
            }
            ToolbarItemGroup(placement: .topBarTrailing) {
                // Ordine pensato per iPhone verticale: prima immissione; filtri+ordinamento in un menu; Saldi; ricarica per ultima.
                Button {
                    movimentiPath.append(MovimentiSchedaRoute.nuoviDati)
                } label: {
                    Image(systemName: "plus.circle.fill")
                }
                .accessibilityLabel("Nuove registrazioni")
                Menu {
                    Button {
                        showFiltriSheet = true
                    } label: {
                        Label("Filtri categoria e conto…", systemImage: "line.3.horizontal.decrease.circle")
                    }
                    Divider()
                    Picker("Ordinamento elenco", selection: $movimentiListSort) {
                        Text("Data (più recenti prima)").tag(ContiMovimentiListSort.dateNewestFirst)
                        Text("N. registrazione (più recenti)").tag(ContiMovimentiListSort.registrationNewestFirst)
                    }
                } label: {
                    Image(
                        systemName: movimentiFiltersActive
                            ? "line.3.horizontal.decrease.circle.fill"
                            : "line.3.horizontal.decrease.circle"
                    )
                }
                .accessibilityLabel("Filtri e ordinamento elenco")
                Button("Saldi") {
                    movimentiPath.append(MovimentiSchedaRoute.saldi)
                }
                .accessibilityLabel("Saldi")
                Button {
                    Task { @MainActor in
                        if provaLanActive {
                            await refreshLanIfLoggedIn()
                        } else {
                            await refreshLightSessionIfLoggedIn(forceReResolveEnc: true, forceCloudRedownload: true)
                        }
                    }
                } label: {
                    if isRefreshingSession {
                        ProgressView()
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                }
                .disabled(isRefreshingSession || isBusy)
                .accessibilityLabel("Aggiorna dal Mac")
            }
        }
        .sheet(isPresented: $showFiltriSheet) {
            NavigationStack(path: $filtriNavigationPath) {
                List {
                    Section {
                        Text(
                            "Mostra solo i movimenti la cui categoria e/o almeno uno dei due conti coincidono con la selezione. " +
                                "Tocca «Categoria» o «Conto» per aprire l’elenco (foglio a scorrimento da basso)."
                        )
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    }
                    Section("Criteri") {
                        Button {
                            filtriNavigationPath.append(MovimentiFiltriPick.category)
                        } label: {
                            LabeledContent("Categoria") {
                                Text(filterCategoryKey.isEmpty ? "Tutte" : filterCategoryKey)
                                    .foregroundStyle(.secondary)
                                    .multilineTextAlignment(.trailing)
                                    .lineLimit(2)
                            }
                        }
                        .buttonStyle(.plain)

                        Button {
                            filtriNavigationPath.append(MovimentiFiltriPick.account)
                        } label: {
                            LabeledContent("Conto") {
                                Text(filterAccountKey.isEmpty ? "Tutti" : filterAccountKey)
                                    .foregroundStyle(.secondary)
                                    .multilineTextAlignment(.trailing)
                                    .lineLimit(2)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                    Section {
                        Text("Visibili: \(filteredMovimentiRecords.count) di \(loggedInRecords.count)")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        if !filterCategoryKey.isEmpty || !filterAccountKey.isEmpty {
                            Button("Reimposta filtri") {
                                filterCategoryKey = ""
                                filterAccountKey = ""
                            }
                        }
                    }
                }
                .onAppear {
                    if !filterCategoryKey.isEmpty, !movimentiCategoryChoices.contains(filterCategoryKey) {
                        filterCategoryKey = ""
                    }
                    if !filterAccountKey.isEmpty, !movimentiAccountChoices.contains(filterAccountKey) {
                        filterAccountKey = ""
                    }
                }
                .navigationTitle("Filtri")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Fine") { showFiltriSheet = false }
                    }
                }
                .navigationDestination(for: MovimentiFiltriPick.self) { pick in
                    switch pick {
                    case .category:
                        MovimentiFilterStringPickView(
                            title: "Categoria",
                            noneLabel: "Tutte",
                            choices: movimentiCategoryChoices,
                            selection: $filterCategoryKey,
                            afterSelect: {
                                if filtriNavigationPath.count > 0 {
                                    filtriNavigationPath.removeLast()
                                }
                            }
                        )
                    case .account:
                        MovimentiFilterStringPickView(
                            title: "Conto",
                            noneLabel: "Tutti",
                            choices: movimentiAccountChoices,
                            selection: $filterAccountKey,
                            afterSelect: {
                                if filtriNavigationPath.count > 0 {
                                    filtriNavigationPath.removeLast()
                                }
                            }
                        )
                    }
                }
            }
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
    }

    /// Riga riepilogo sotto la data (filtri attivi + conteggio).
    private var movimentiFiltriSummaryLine: String? {
        var parts: [String] = []
        if let c = activeCategoryFilter {
            parts.append("Categoria: \(c)")
        }
        if let a = activeAccountFilter {
            parts.append("Conto: \(a)")
        }
        let base = parts.joined(separator: " · ")
        if filteredMovimentiRecords.count != loggedInRecords.count || !parts.isEmpty {
            let suffix = " — \(filteredMovimentiRecords.count)/\(loggedInRecords.count)"
            return base.isEmpty ? String(suffix.dropFirst(3)) : base + suffix
        }
        return nil
    }

    private func italianLongToday() -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "it_IT")
        f.dateStyle = .long
        f.timeStyle = .none
        f.timeZone = .current
        return f.string(from: Date())
    }

    private var rowPrimaryText: Color {
        colorScheme == .dark ? .white : Color.primary
    }

    private func amountColor(_ value: Decimal) -> Color {
        if value < .zero { return Color.red }
        if value > .zero { return Color.green }
        return Color.secondary
    }

    private func accountLine(_ row: ContiRecordRow) -> String {
        if row.accountSecondary.isEmpty {
            return row.accountPrimary
        }
        return "\(row.accountPrimary) → \(row.accountSecondary)"
    }

    /// Precompila il campo email con l’ultimo accesso riuscito (non sovrascrive testo già inserito).
    private func applySavedLoginEmailIfNeeded() {
        guard email.isEmpty else { return }
        let saved = ContiLightLastLoginEmail.load()
        if !saved.isEmpty {
            email = saved
        }
    }

    private func loginWithProvaLan() {
        guard !isBusy else { return }
        let emailTrim = email.trimmingCharacters(in: .whitespacesAndNewlines)
        let passwordTrim = password.trimmingCharacters(in: .whitespacesAndNewlines)
        email = emailTrim
        password = passwordTrim
        guard !emailTrim.isEmpty, !passwordTrim.isEmpty else { return }
        isBusy = true
        message = "Apro l'elenco…"
        let code = provaCode
        Task { @MainActor in
            let opened = await openProvaFromLastSession(emailTrim: emailTrim, passwordTrim: passwordTrim)
            isBusy = false
            if opened {
                await syncProvaAfterOpen(code: code, emailTrim: emailTrim, passwordTrim: passwordTrim)
                return
            }
            isBusy = true
            message = "Primo collegamento: cerco il Mac…"
            defer { isBusy = false }
            do {
                let light = try await lanClient.pairAndPull(code: code)
                guard ContiDatabase.tryLogin(db: light, email: emailTrim, password: passwordTrim) != nil else {
                    message = "Password non riconosciuta sul Mac."
                    return
                }
                await adoptMacLight(light, emailTrim: emailTrim, fresh: true)
            } catch {
                let detail = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                message = "Per la prima apertura il Mac deve essere acceso. \(detail)"
            }
        }
    }

    /// Dopo l'apertura, allinea l'elenco con il Mac senza tenere ferma la schermata di accesso.
    private func syncProvaAfterOpen(code: String, emailTrim: String, passwordTrim: String) async {
        message = "Sincronizzo con il Mac…"
        do {
            let light = try await lanClient.pairAndPull(code: code)
            guard ContiDatabase.tryLogin(db: light, email: emailTrim, password: passwordTrim) != nil else {
                message = "Password non riconosciuta sul Mac."
                return
            }
            await adoptMacLight(light, emailTrim: emailTrim, fresh: false)
        } catch {
            if isMacAppClosed(error) {
                if lightDropboxDirty {
                    await flushLanIfDirty()
                }
                message = macClosedSyncMessage
                if !lanMacClosedNoticeShown {
                    lanMacClosedNoticeShown = true
                    lanNoticeText = macClosedSyncMessage
                    lanNoticePresented = true
                }
                return
            }
            message = "Mac spento. L'elenco resta quello del telefono."
            lanNoticeText = "Mac spento. Le registrazioni nuove restano sul telefono e si inviano quando il Mac è acceso."
            lanNoticePresented = true
        }
    }

    private func adoptMacLight(_ light: [String: Any], emailTrim: String, fresh: Bool) async {
        ContiLightLastLoginEmail.save(emailTrim)
        provaLanActive = true
        lastScenePhaseRefreshAt = Date()
        if fresh {
            movimentiPath = NavigationPath()
            filterCategoryKey = ""
            filterAccountKey = ""
        }
        var session = light
        var stillUnsent = false
        var sentCount = 0
        let previousMac = lanFingerprints
        let key = await lanClient.encryptionKey()
        lanKeyText = key
        if !key.isEmpty, let pending = try? ContiDatabase.loadLanUnsentSession(keyString: key) {
            let applied = ContiLanClient.applyingUnsent(pending, onto: light)
            if applied.unsent.isEmpty {
                ContiDatabase.removeLanUnsentSession(ifGeneration: ContiDatabase.lanUnsentGenerationNow())
            } else {
                do {
                    session = try await lanClient.push(records: applied.unsent)
                    ContiDatabase.removeLanUnsentSession(ifGeneration: ContiDatabase.lanUnsentGenerationNow())
                    sentCount = applied.unsent.count
                } catch {
                    session = applied.merged
                    stillUnsent = true
                }
            }
        }
        loggedInSessionDb = session as NSDictionary
        sessionKeyURL = nil
        sessionLightEncURL = nil
        lightDropboxDirty = stillUnsent
        lanFingerprints = ContiLanClient.fingerprints(of: stillUnsent ? light : session)
        loggedInRecords = ContiDatabase.displayRecords(from: session, sort: movimentiListSort)
        movimentiDisplayName = ContiDatabase.displayNameForHeader(db: session, email: emailTrim)
        rememberLanSnapshot(stillUnsent ? light : session)
        let fromMac = ContiLanClient.changedCount(
            from: previousMac,
            to: ContiLanClient.fingerprints(of: light)
        )
        if stillUnsent {
            message = "Registrazioni ancora solo sul telefono. Si inviano quando il Mac risponde."
            lanNoticeText = "Le registrazioni immesse col Mac spento sono ancora sul telefono."
        } else {
            message = "Collegato al Mac."
            lanNoticeText = ContiLanClient.exchangeNotice(toPhone: fromMac, toMac: sentCount)
            await lanClient.reportExchange(toPhone: fromMac, toMac: sentCount)
        }
        lanNoticePresented = true
        lanTokenKnown = await lanClient.hasSavedToken()
    }

    /// Apre l'ultimo elenco tenuto sul telefono se il Mac non risponde.
    private func openProvaFromLastSession(emailTrim: String, passwordTrim: String) async -> Bool {
        let key = await lanClient.encryptionKey()
        guard !key.isEmpty else { return false }
        lanKeyText = key
        let last = try? ContiDatabase.loadLanLastSession(keyString: key)
        let pending = try? ContiDatabase.loadLanUnsentSession(keyString: key)
        let base = last ?? pending
        guard let base else { return false }
        let applied = last.flatMap { confirmed in
            pending.map { ContiLanClient.applyingUnsent($0, onto: confirmed) }
        }
        let session = applied?.merged ?? base
        let unsent = applied?.unsent ?? []
        guard ContiDatabase.tryLogin(db: session, email: emailTrim, password: passwordTrim) != nil else {
            return false
        }
        let stillUnsent = !unsent.isEmpty || (last == nil && pending != nil)
        ContiLightLastLoginEmail.save(emailTrim)
        provaLanActive = true
        lastScenePhaseRefreshAt = Date()
        movimentiPath = NavigationPath()
        filterCategoryKey = ""
        filterAccountKey = ""
        loggedInSessionDb = session as NSDictionary
        sessionKeyURL = nil
        sessionLightEncURL = nil
        lightDropboxDirty = stillUnsent
        lanFingerprints = ContiLanClient.fingerprints(of: last ?? [:])
        loggedInRecords = ContiDatabase.displayRecords(from: session, sort: movimentiListSort)
        movimentiDisplayName = ContiDatabase.displayNameForHeader(db: session, email: emailTrim)
        message = "Elenco del telefono."
        lanNoticePresented = false
        lanTokenKnown = await lanClient.hasSavedToken()
        return true
    }

    private func rememberLanSnapshot(_ db: [String: Any]) {
        let key = lanKeyText
        guard !key.isEmpty else { return }
        try? ContiDatabase.saveLanLastSession(db: db, keyString: key)
    }

    private func loginWithPassword() {
        guard let folder = dataFolderURL else { return }
        guard !isBusy else { return }
        let emailTrim = email.trimmingCharacters(in: .whitespacesAndNewlines)
        let passwordTrim = password.trimmingCharacters(in: .whitespacesAndNewlines)
        email = emailTrim
        password = passwordTrim
        guard !emailTrim.isEmpty, !passwordTrim.isEmpty else { return }

        isBusy = true
        // Poi: lettura/decifratura `*_light.enc`, eventuale attesa file (es. Dropbox) e sync con il .enc completo.
        message = "Attendere un momento, per favore"
        let folderURL = folder

        Task { @MainActor in
            defer { isBusy = false }
            let packet = await runLoginPacket(
                emailTrim: emailTrim,
                passwordTrim: passwordTrim,
                folderURL: folderURL,
                lightEncURLIfKnown: pickedLightEncURL,
                forceCloudRedownload: true
            )
            applyLoginPacket(packet, emailTrim: emailTrim, passwordTrim: passwordTrim)
        }
    }

    /// Accesso con Face ID / Touch ID: recupera la password dal Keychain dopo il prompt biometrico.
    private func loginWithBiometrics() {
        guard !isBusy else { return }
        let emailTrim = email.trimmingCharacters(in: .whitespacesAndNewlines)
        email = emailTrim
        guard !emailTrim.isEmpty else { return }
        isBusy = true
        message = "Autenticazione…"
        Task { @MainActor in
            do {
                password = try ContiLightBiometricLogin.loadPasswordUnlockingWithBiometrics(email: emailTrim)
            } catch {
                isBusy = false
                message = (error as NSError).localizedDescription
                return
            }
            isBusy = false
            loginWithProvaLan()
        }
    }

    /// Ricarica silenziosamente il file light dalla cartella (stesso compito del tasto Aggiorna quando `forceReResolveEnc` è attivo).
    /// Default: risolve di nuovo il path `*_light.enc` (Importo allineato al file su disco dopo sync Dropbox / Files).
    /// `forceCloudRedownload`: scarta la copia File Provider e riscarica (Aggiorna / pull); non usarlo a ogni ritorno in primo piano.
    private func pollLanRevision() async {
        guard provaLanActive, !isBusy, !isRefreshingSession else { return }
        if lightDropboxDirty {
            await flushLanIfDirty()
        }
        await refreshLanIfLoggedIn(quiet: true)
    }

    private func refreshLanIfLoggedIn(quiet: Bool = false) async {
        guard provaLanActive, loggedInSessionDb != nil, !isBusy, !isRefreshingSession else { return }
        isRefreshingSession = true
        defer { isRefreshingSession = false }
        do {
            let previousShown = ContiLanClient.fingerprints(
                of: (loggedInSessionDb as? [String: Any]) ?? [:]
            )
            let light = try await lanClient.pull(quiet: quiet)
            var session = light
            if lightDropboxDirty, !lanKeyText.isEmpty,
               let pending = try? ContiDatabase.loadLanUnsentSession(keyString: lanKeyText) {
                let applied = ContiLanClient.applyingUnsent(pending, onto: light)
                session = applied.merged
                if applied.unsent.isEmpty {
                    lightDropboxDirty = false
                    ContiDatabase.removeLanUnsentSession(ifGeneration: ContiDatabase.lanUnsentGenerationNow())
                }
            }
            if !lightDropboxDirty, !lanDidClearPending {
                lanDidClearPending = await lanClient.clearPendingNotice()
            }
            let fromMac = ContiLanClient.changedCount(
                from: lanFingerprints,
                to: ContiLanClient.fingerprints(of: light)
            )
            let shown = ContiLanClient.fingerprints(of: session)
            lastScenePhaseRefreshAt = Date()
            lanFingerprints = ContiLanClient.fingerprints(of: light)
            if fromMac > 0 || !quiet {
                lanNoticeText = ContiLanClient.exchangeNotice(toPhone: fromMac, toMac: 0)
                lanNoticePresented = true
                await lanClient.reportExchange(toPhone: fromMac, toMac: 0)
            }
            guard shown != previousShown else { return }
            loggedInSessionDb = session as NSDictionary
            loggedInRecords = ContiDatabase.displayRecords(from: session, sort: movimentiListSort)
            movimentiDisplayName = ContiDatabase.displayNameForHeader(db: session, email: email)
            rememberLanSnapshot(light)
        } catch {
            if !quiet {
                message = "Mac non raggiungibile. Le registrazioni restano sul telefono."
            }
        }
    }

    private func flushLanIfDirty() async {
        guard provaLanActive, lightDropboxDirty, var db = loggedInSessionDb as? [String: Any] else { return }
        let generation = ContiDatabase.lanUnsentGenerationNow()
        let dirty = ContiLanClient.dirtyRecords(in: &db, baseline: lanFingerprints)
        loggedInSessionDb = db as NSDictionary
        if dirty.isEmpty {
            ContiDatabase.removeLanUnsentSession(ifGeneration: generation)
            if ContiDatabase.lanUnsentGenerationNow() == generation {
                lightDropboxDirty = false
                lanFingerprints = ContiLanClient.fingerprints(of: db)
            }
            return
        }
        do {
            let light = try await lanClient.push(records: dirty)
            if ContiDatabase.lanUnsentGenerationNow() == generation {
                loggedInSessionDb = light as NSDictionary
                loggedInRecords = ContiDatabase.displayRecords(from: light, sort: movimentiListSort)
                lanFingerprints = ContiLanClient.fingerprints(of: light)
                ContiDatabase.removeLanUnsentSession(ifGeneration: generation)
                lightDropboxDirty = false
                rememberLanSnapshot(light)
            }
            message = "Salvate sul Mac."
            lanNoticeText = ContiLanClient.exchangeNotice(toPhone: 0, toMac: dirty.count)
            lanNoticePresented = true
            lanMacClosedNoticeShown = false
        } catch {
            if isMacAppClosed(error) {
                message = macClosedSyncMessage
                if !lanMacClosedNoticeShown {
                    lanMacClosedNoticeShown = true
                    lanNoticeText = macClosedSyncMessage
                    lanNoticePresented = true
                }
                return
            }
            let detail = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            message = "Registrazioni ancora solo sul telefono. \(detail)"
        }
    }

    private var macClosedSyncMessage: String {
        "Il Mac è chiuso. Le registrazioni restano sul telefono. Alla riapertura, se Light è chiusa, il Mac avvisa di riaprirla."
    }

    private func isMacAppClosed(_ error: Error) -> Bool {
        let detail = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        return detail.contains("app_chiusa")
    }

    private func refreshLightSessionIfLoggedIn(forceReResolveEnc: Bool = true, forceCloudRedownload: Bool = false) async {
        if provaLanActive { return }
        guard loggedInSessionDb != nil, let folder = dataFolderURL else { return }
        let emailTrim = email.trimmingCharacters(in: .whitespacesAndNewlines)
        let passwordTrim = password.trimmingCharacters(in: .whitespacesAndNewlines)
        // Niente lettura biometrica qui (eviterebbe prompt a ogni ritorno in primo piano).
        guard !emailTrim.isEmpty, !passwordTrim.isEmpty else { return }
        guard !isBusy, !isRefreshingSession else { return }

        // Non sostituire la lista con il file Dropbox finché le registrazioni di questa sessione
        // non sono state scritte: al ritorno in primo piano sparirebbero.
        if lightDropboxDirty { return }
        isRefreshingSession = true
        defer { isRefreshingSession = false }

        let encRef: URL?
        if forceReResolveEnc {
            encRef = nil
        } else {
            encRef = sessionLightEncURL
        }

        let packet = await runLoginPacket(
            emailTrim: emailTrim,
            passwordTrim: passwordTrim,
            folderURL: folder,
            lightEncURLIfKnown: encRef,
            skipSessionWorkspaceLock: true,
            forceCloudRedownload: forceCloudRedownload
        )
        guard let newDb = packet.sessionDb,
              packet.keyURL != nil,
              packet.lightEncURL != nil else { return }
        loggedInSessionDb = newDb
        if let d = newDb as? [String: Any] {
            loggedInRecords = ContiDatabase.displayRecords(from: d, sort: movimentiListSort)
            movimentiDisplayName = ContiDatabase.displayNameForHeader(db: d, email: emailTrim)
        } else {
            loggedInRecords = packet.records
            movimentiDisplayName = emailTrim
        }
        sessionKeyURL = packet.keyURL
        sessionLightEncURL = packet.lightEncURL
        if let pm = packet.periodicStartupMessage?.trimmingCharacters(in: .whitespacesAndNewlines), !pm.isEmpty {
            periodicStartupAlertText = pm
            periodicStartupAlertPresented = true
        }
        lastScenePhaseRefreshAt = Date()
    }

    private func releaseSessionLockIfOwned() {
        guard let folder = dataFolderURL else {
            ContiDatabase.clearLocalInstanceSessionState()
            return
        }
        let access = folder.startAccessingSecurityScopedResource()
        defer {
            if access { folder.stopAccessingSecurityScopedResource() }
        }
        if access {
            ContiDatabase.releaseSessionWorkspaceLockOnClose(in: folder)
        } else {
            ContiDatabase.clearLocalInstanceSessionState()
        }
    }

    private func closeCurrentSessionAndReleaseLock() {
        releaseSessionLockIfOwned()
        provaLanActive = false
        lightDropboxDirty = false
        lanKeyText = ""
        loggedInSessionDb = nil
        loggedInRecords = []
        movimentiDisplayName = ""
        sessionKeyURL = nil
        sessionLightEncURL = nil
        movimentiPath = NavigationPath()
    }

    /// Tiene la sessione in memoria e ne fa una copia cifrata fuori da Dropbox.
    private func rememberSessionForDropboxFlush(_ db: [String: Any], note: String) {
        if provaLanActive {
            loggedInSessionDb = db as NSDictionary
            loggedInRecords = ContiDatabase.displayRecords(from: db, sort: movimentiListSort)
            lightDropboxDirty = true
            message = note
            if !lanKeyText.isEmpty {
                _ = try? ContiDatabase.saveLanUnsentSession(db: db, keyString: lanKeyText)
            }
            Task { @MainActor in
                if lanKeyText.isEmpty {
                    let key = await lanClient.encryptionKey()
                    lanKeyText = key
                    if !key.isEmpty {
                        _ = try? ContiDatabase.saveLanUnsentSession(db: db, keyString: key)
                    }
                }
                await flushLanIfDirty()
            }
            return
        }
        loggedInSessionDb = db as NSDictionary
        loggedInRecords = ContiDatabase.displayRecords(from: db, sort: movimentiListSort)
        lightDropboxDirty = true
        message = note
        guard let folder = dataFolderURL, let key = sessionKeyURL else { return }
        DispatchQueue.global(qos: .utility).async {
            let access = folder.startAccessingSecurityScopedResource()
            defer {
                if access { folder.stopAccessingSecurityScopedResource() }
            }
            guard access else { return }
            try? ContiDatabase.savePendingLightSession(db: db, keyURL: key)
        }
    }

    /// Scrive ``*_light.enc`` una sola volta, con tutte le registrazioni della sessione.
    private func flushLightSessionToDropboxIfDirty() async {
        guard lightDropboxDirty,
              let db = loggedInSessionDb as? [String: Any],
              let folder = dataFolderURL,
              let key = sessionKeyURL,
              let enc = sessionLightEncURL else { return }
        let emailTrim = email.trimmingCharacters(in: .whitespacesAndNewlines)
        let passwordTrim = password.trimmingCharacters(in: .whitespacesAndNewlines)
        let generationAtStart = ContiDatabase.pendingLightGenerationNow()
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                let access = folder.startAccessingSecurityScopedResource()
                defer {
                    if access { folder.stopAccessingSecurityScopedResource() }
                }
                var wrote = false
                if access {
                    let target: URL? = {
                        if let canonical = ContiDatabase.resolvePrimaryEncURL(inFolder: folder, email: emailTrim),
                           ContiDatabase.lightEncURLIsInsideDataFolder(canonical, folder: folder) {
                            return canonical
                        }
                        if ContiDatabase.lightEncURLIsInsideDataFolder(enc, folder: folder) {
                            return enc
                        }
                        return nil
                    }()
                    do {
                        guard let target else {
                            throw ContiLightImmissioneError.message(
                                "Salvataggio bloccato: il file light non è nella cartella dati. Riseleziona Dropbox → ContiCursor."
                            )
                        }
                        _ = try ContiDatabase.persistSessionDbToEncryptedFiles(
                            sessionDb: db,
                            recordForSaldi: [:],
                            lightEncURL: target,
                            keyURL: key,
                            email: emailTrim,
                            password: passwordTrim
                        )
                        ContiDatabase.removePendingLightSession(ifGeneration: generationAtStart)
                        wrote = true
                        DispatchQueue.main.async {
                            self.sessionLightEncURL = target
                        }
                    } catch {
                        wrote = false
                        _ = try? ContiDatabase.savePendingLightSession(db: db, keyURL: key)
                        let detail = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                        DispatchQueue.main.async {
                            self.message = "Registrazioni non scritte su Dropbox. \(detail)"
                        }
                    }
                }
                DispatchQueue.main.async {
                    if wrote, ContiDatabase.pendingLightGenerationNow() == generationAtStart {
                        self.lightDropboxDirty = false
                    }
                    cont.resume()
                }
            }
        }
    }

    /// Carica e decifra il DB in background (come `loginWithPassword`).
    private func runLoginPacket(
        emailTrim: String,
        passwordTrim: String,
        folderURL: URL,
        lightEncURLIfKnown: URL?,
        skipSessionWorkspaceLock: Bool = false,
        forceCloudRedownload: Bool = false
    ) async -> LoginResultPacket {
        await withCheckedContinuation { (cont: CheckedContinuation<LoginResultPacket, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                let folderAccess = folderURL.startAccessingSecurityScopedResource()
                var renewBookmark = true
                defer {
                    if folderAccess {
                        if renewBookmark {
                            ContiLightFolderBookmark.renew(from: folderURL)
                        }
                        folderURL.stopAccessingSecurityScopedResource()
                    }
                }
                guard folderAccess else {
                    cont.resume(
                        returning: LoginResultPacket(
                            message: "Impossibile accedere alla cartella (permessi). Scegli di nuovo la cartella con «Scegli cartella…».",
                            records: [],
                            sessionDb: nil,
                            keyURL: nil,
                            lightEncURL: nil,
                            periodicStartupMessage: nil
                        )
                    )
                    return
                }

                let packet: LoginResultPacket
                if !skipSessionWorkspaceLock {
                    do {
                        try ContiDatabase.assertNoSessionWorkspaceLockBeforeOpen(in: folderURL)
                    } catch {
                        let s = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                        packet = LoginResultPacket(
                            message: s,
                            records: [],
                            sessionDb: nil,
                            keyURL: nil,
                            lightEncURL: nil,
                            periodicStartupMessage: nil
                        )
                        cont.resume(returning: packet)
                        return
                    }
                }
                if let reject = ContiDatabase.rejectReasonIfNotDesktopDataFolder(folderURL) {
                    renewBookmark = false
                    ContiLightFolderBookmark.clear()
                    packet = LoginResultPacket(
                        message: reject,
                        records: [],
                        sessionDb: nil,
                        keyURL: nil,
                        lightEncURL: nil,
                        periodicStartupMessage: nil
                    )
                    cont.resume(returning: packet)
                    return
                }
                guard let keyRef = ContiDatabase.preferredKeyFileURL(inFolder: folderURL) else {
                    packet = LoginResultPacket(
                        message: "Nessun file .key nella cartella. Copia qui conti_di_casa.key (stesso del desktop).",
                        records: [],
                        sessionDb: nil,
                        keyURL: nil,
                        lightEncURL: nil,
                        periodicStartupMessage: nil
                    )
                    cont.resume(returning: packet)
                    return
                }
                // Il segnaposto si controlla in ``acquireSessionWorkspaceLockForOpen`` (stesso criteri «materiato»/scrittura).
                var encRef: URL
                let knownInFolder = lightEncURLIfKnown.flatMap { known -> URL? in
                    ContiDatabase.lightEncURLIsInsideDataFolder(known, folder: folderURL) ? known : nil
                }
                if let knownInFolder {
                    encRef = knownInFolder
                } else if let resolved = ContiDatabase.resolvePrimaryEncURL(inFolder: folderURL, email: emailTrim) {
                    encRef = resolved
                } else if let any = ContiDatabase.lightFileCandidates(inFolder: folderURL, email: emailTrim).first {
                    encRef = any
                } else {
                    let stem = ContiDatabase.userEncFilenameStem(forEmail: emailTrim)
                    packet = LoginResultPacket(
                        message: """
                        Nessun file light trovato. Serve solo `*_light.enc` (mai il database grande). \
                        Dal desktop salva e controlla che esista \(stem)_light.enc nella stessa cartella del file .key.
                        """,
                        records: [],
                        sessionDb: nil,
                        keyURL: nil,
                        lightEncURL: nil,
                        periodicStartupMessage: nil
                    )
                    cont.resume(returning: packet)
                    return
                }
                let fullEncURL = folderURL.standardizedFileURL.appendingPathComponent(
                    "\(ContiDatabase.userEncFilenameStem(forEmail: emailTrim)).enc",
                    isDirectory: false
                )
                let cloudWait = ContiDatabase.requestFreshCloudMaterialization(
                    of: encRef,
                    forceEvict: forceCloudRedownload && knownInFolder == nil
                )
                let lightSize = (try? FileManager.default.attributesOfItem(atPath: encRef.path)[.size] as? NSNumber)?.int64Value ?? 0
                if forceCloudRedownload, knownInFolder == nil, lightSize <= 0,
                   ContiDatabase.lightFileCandidates(inFolder: folderURL, email: emailTrim).isEmpty {
                    packet = LoginResultPacket(
                        message: """
                        Non riesco a scaricare il file light aggiornato da Dropbox (la copia sul telefono era probabilmente quella dell’ultima apertura). \
                        Apri l’app Dropbox, attendi che \(encRef.lastPathComponent) sia in linea, poi in Conti Light tocca «Allinea file con Dropbox» e Accedi. \
                        Se Dropbox è già aggiornato, usa «Cambia cartella…» e riseleziona la stessa cartella.
                        """,
                        records: [],
                        sessionDb: nil,
                        keyURL: nil,
                        lightEncURL: nil,
                        periodicStartupMessage: nil
                    )
                    cont.resume(returning: packet)
                    return
                }
                var dropboxWaitPaths: [URL] = [keyRef, encRef]
                if FileManager.default.fileExists(atPath: fullEncURL.path) {
                    dropboxWaitPaths.append(fullEncURL)
                }
                let waited = ContiDatabase.waitForPathsStableIfDropbox(dropboxWaitPaths)
                // Dopo evict/download: breve pausa + seconda stabilità sull’`.enc` (il provider può finire di scrivere dopo «current»).
                Thread.sleep(forTimeInterval: 0.45)
                let waited2 = ContiDatabase.waitForFileStableIfDropbox(encRef)
                let totalWait = cloudWait + waited + waited2
                let syncWaitNote: String = totalWait >= 1.0
                    ? String(format: "Attesa sincronizzazione Dropbox: %.1fs.", totalWait)
                    : ""
                var pendingFlushNote = ""
                var sourceNote = ""

                do {
                    let keyString = try ContiDatabase.coordinatedStringContents(of: keyRef, encoding: .utf8)
                    let pickedAccess = knownInFolder?.startAccessingSecurityScopedResource() ?? false
                    defer {
                        if pickedAccess, let known = knownInFolder {
                            known.stopAccessingSecurityScopedResource()
                        }
                    }
                    let freshest = try ContiDatabase.readFreshestLightDatabase(
                        inFolder: folderURL,
                        email: emailTrim,
                        keyString: keyString,
                        preferredURL: knownInFolder
                    )
                    encRef = freshest.url
                    if let canonical = ContiDatabase.resolvePrimaryEncURL(inFolder: folderURL, email: emailTrim),
                       ContiDatabase.lightEncURLIsInsideDataFolder(canonical, folder: folderURL) {
                        encRef = canonical
                    }
                    var db = freshest.db
                    let day = freshest.generatedDay ?? "sconosciuta"
                    sourceNote = "Aperto \(encRef.lastPathComponent), dati del \(day)."
                    if ContiDatabase.pendingLightSessionExists() {
                        do {
                            if let pendingDB = try ContiDatabase.loadPendingLightSessionDB(keyString: keyString) {
                                let pendingNewer = ContiDatabase.pendingLightSessionShouldReplaceCloud(
                                    cloudDB: db,
                                    pendingDB: pendingDB,
                                    cloudURL: encRef
                                )
                                var merged = db
                                let recovered = pendingNewer
                                    ? ContiDatabase.mergeLightNewRecordsIntoMain(main: &merged, light: pendingDB)
                                    : 0
                                if recovered > 0 {
                                    db = merged
                                    do {
                                        _ = try ContiDatabase.persistSessionDbToEncryptedFiles(
                                            sessionDb: db,
                                            recordForSaldi: [:],
                                            lightEncURL: encRef,
                                            keyURL: keyRef,
                                            email: emailTrim,
                                            password: passwordTrim
                                        )
                                        ContiDatabase.removePendingLightSession(
                                            ifGeneration: ContiDatabase.pendingLightGenerationNow()
                                        )
                                        pendingFlushNote = recovered == 1
                                            ? "La registrazione inserita in questa app è stata scritta nel file light della cartella dati."
                                            : "Le \(recovered) registrazioni inserite in questa app sono state scritte nel file light della cartella dati."
                                    } catch {
                                        pendingFlushNote = "Le registrazioni inserite in questa app restano sul telefono e non sono ancora nel file Dropbox. \(error.localizedDescription)"
                                    }
                                } else {
                                    ContiDatabase.quarantineStalePendingLightSession()
                                }
                            }
                        } catch {
                            pendingFlushNote = "Copia locale in sospeso non applicata, uso il file Dropbox. \(error.localizedDescription)"
                        }
                    }
                    if ContiDatabase.tryLogin(db: db, email: emailTrim, password: passwordTrim) != nil {
                        if !skipSessionWorkspaceLock {
                            do {
                                try ContiDatabase.acquireSessionWorkspaceLockForOpen(in: folderURL)
                            } catch {
                                let s = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                                packet = LoginResultPacket(
                                    message: s,
                                    records: [],
                                    sessionDb: nil,
                                    keyURL: nil,
                                    lightEncURL: nil,
                                    periodicStartupMessage: nil
                                )
                                cont.resume(returning: packet)
                                return
                            }
                        }
                        // Login/refresh in sola lettura: nessuna riscrittura dei `.enc` in questa fase.
                        // Le scritture restano solo nelle azioni esplicite utente (nuova immissione/modifica/annullamento).
                        let sessionDb: [String: Any] = db
                        let periodicStartupMessage: String? = nil
                        let rows = ContiDatabase.displayRecords(from: sessionDb)
                        let baseMsg = rows.isEmpty
                            ? "Accesso effettuato. Nessun movimento nel file light."
                            : "Accesso effettuato."
                        var notes: [String] = []
                        if !sourceNote.isEmpty { notes.append(sourceNote) }
                        if !syncWaitNote.isEmpty { notes.append(syncWaitNote) }
                        if !pendingFlushNote.isEmpty { notes.append(pendingFlushNote) }
                        let msgOut = notes.isEmpty ? baseMsg : baseMsg + "\n\n" + notes.joined(separator: "\n")
                        packet = LoginResultPacket(
                            message: msgOut,
                            records: rows,
                            sessionDb: sessionDb as NSDictionary,
                            keyURL: keyRef,
                            lightEncURL: encRef,
                            periodicStartupMessage: periodicStartupMessage
                        )
                    } else {
                        packet = LoginResultPacket(
                            message: "Accesso negato (email/password o profilo non valido).",
                            records: [],
                            sessionDb: nil,
                            keyURL: nil,
                            lightEncURL: nil,
                            periodicStartupMessage: nil
                        )
                    }
                } catch {
                    let msg: String
                    if let ce = error as? ContiDBError {
                        msg = ce.localizedDescription
                    } else {
                        msg = "Lettura file o elaborazione: \(error.localizedDescription)"
                    }
                    packet = LoginResultPacket(
                        message: msg,
                        records: [],
                        sessionDb: nil,
                        keyURL: nil,
                        lightEncURL: nil,
                        periodicStartupMessage: nil
                    )
                }
                cont.resume(returning: packet)
            }
        }
    }

    private func applyLoginPacket(_ packet: LoginResultPacket, emailTrim: String, passwordTrim: String) {
        var msg = packet.message
        if packet.sessionDb != nil {
            ContiLightLastLoginEmail.save(emailTrim)
            if savePasswordForBiometrics, ContiLightBiometricLogin.biometricsAvailable() {
                do {
                    try ContiLightBiometricLogin.savePasswordForBiometricUnlock(
                        email: emailTrim,
                        password: passwordTrim
                    )
                } catch {
                    msg += "\n\n\(ContiLightBiometricLogin.biometricLabel()): non salvato — \(error.localizedDescription)"
                }
            } else {
                ContiLightBiometricLogin.deletePassword(forEmail: emailTrim)
            }
        }
        message = msg
        if let dbObj = packet.sessionDb {
            // Evita che `.active` immediato dopo il login lanci una seconda lettura in concorrenza col Task ritardato sotto.
            lastScenePhaseRefreshAt = Date()
            movimentiPath = NavigationPath()
            filterCategoryKey = ""
            filterAccountKey = ""
            loggedInSessionDb = dbObj
            sessionKeyURL = packet.keyURL
            sessionLightEncURL = packet.lightEncURL
            if let d = dbObj as? [String: Any] {
                loggedInRecords = ContiDatabase.displayRecords(from: d, sort: movimentiListSort)
                movimentiDisplayName = ContiDatabase.displayNameForHeader(db: d, email: emailTrim)
            } else {
                loggedInRecords = packet.records
                movimentiDisplayName = emailTrim
            }
            if let pm = packet.periodicStartupMessage?.trimmingCharacters(in: .whitespacesAndNewlines), !pm.isEmpty {
                periodicStartupAlertText = pm
                periodicStartupAlertPresented = true
            }
            // Ricarica dopo che Dropbox/Files ha potuto finire la copia locale del `*_light.enc` (stesso effetto del tasto Aggiorna).
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 4_000_000_000)
                await refreshLightSessionIfLoggedIn()
            }
        } else {
            closeCurrentSessionAndReleaseLock()
        }
    }
}

/// Esito login dal thread in background; `sessionDb` solo se autenticazione riuscita (per saldi / immissioni future).
private struct LoginResultPacket: @unchecked Sendable {
    let message: String
    let records: [ContiRecordRow]
    let sessionDb: NSDictionary?
    let keyURL: URL?
    let lightEncURL: URL?
    /// Testo lungo per alert (solo se sono state create occorrenze periodiche).
    let periodicStartupMessage: String?
}

private struct FolderPickRequest: Identifiable, Hashable {
    let id = UUID()
}

// MARK: - Document picker cartella (senza copia, per bookmark)

private struct DocumentFolderPickerRepresentable: UIViewControllerRepresentable {
    var onPick: (URL) -> Void
    var onCancel: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onPick: onPick, onCancel: onCancel)
    }

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.folder], asCopy: false)
        picker.delegate = context.coordinator
        picker.allowsMultipleSelection = false
        return picker
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onPick: (URL) -> Void
        let onCancel: () -> Void

        init(onPick: @escaping (URL) -> Void, onCancel: @escaping () -> Void) {
            self.onPick = onPick
            self.onCancel = onCancel
        }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            guard let u = urls.first else {
                DispatchQueue.main.async { self.onCancel() }
                return
            }
            DispatchQueue.main.async {
                self.onPick(u)
            }
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            DispatchQueue.main.async {
                self.onCancel()
            }
        }
    }
}

private struct DocumentFilePickerRepresentable: UIViewControllerRepresentable {
    var onPick: (URL) -> Void
    var onCancel: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onPick: onPick, onCancel: onCancel)
    }

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let encType = UTType(filenameExtension: "enc") ?? .data
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [encType], asCopy: false)
        picker.delegate = context.coordinator
        picker.allowsMultipleSelection = false
        return picker
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onPick: (URL) -> Void
        let onCancel: () -> Void

        init(onPick: @escaping (URL) -> Void, onCancel: @escaping () -> Void) {
            self.onPick = onPick
            self.onCancel = onCancel
        }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            guard let u = urls.first else {
                DispatchQueue.main.async { self.onCancel() }
                return
            }
            DispatchQueue.main.async { self.onPick(u) }
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            DispatchQueue.main.async { self.onCancel() }
        }
    }
}

#Preview {
    ContentView()
}
