import Foundation
import Network
import Security

enum ContiLanError: LocalizedError {
    case message(String)

    var errorDescription: String? {
        switch self {
        case .message(let text):
            return text
        }
    }
}

/// Chiama il Mac sulla rete locale. Non scrive su Dropbox.
/// Un colloquio alla volta: due invii insieme non si mescolano sulla stessa connessione.
actor ContiLanClient {
    private let queue = DispatchQueue(label: "conti.light.lan")
    private var connection: NWConnection?
    private var exchangeId = UUID()
    private(set) var confirmedRevision: Int = -1
    private var ready = false
    private var keyText = ""
    private let tokenKey = "ContiLight.lanToken"
    private let keyDefaults = "ContiLight.lanKey"
    private let keychainAccount = "ContiLight.lanFernet"

    var savedToken: String {
        get { UserDefaults.standard.string(forKey: tokenKey) ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: tokenKey) }
    }

    func hasSavedToken() -> Bool {
        !savedToken.isEmpty
    }

    func encryptionKey() -> String {
        if keyText.isEmpty {
            keyText = readStoredKey()
        }
        return keyText
    }

    func forgetPairing() {
        savedToken = ""
        keyText = ""
        deleteStoredKey()
        connection?.cancel()
        connection = nil
        ready = false
    }

    func pairAndPull(code: String) async throws -> [String: Any] {
        try await ensureConnection(code: code, force: true)
        return try await pull()
    }

    func pull(quiet: Bool = false) async throws -> [String: Any] {
        try await ensureConnection(code: "", force: false)
        var message: [String: Any] = ["op": "pull"]
        if quiet {
            message["quiet"] = true
        }
        let reply = try await roundTrip(message)
        guard (reply["op"] as? String) == "pull_ok", let light = reply["light"] as? [String: Any] else {
            throw ContiLanError.message(Self.errorText(reply) ?? "Il Desktop non ha inviato i dati.")
        }
        rememberRevision(reply)
        return light
    }

    /// Dice al Mac quante registrazioni sono cambiate, così l'avviso è lo stesso sui due lati.
    func reportExchange(toPhone: Int, toMac: Int) async {
        do {
            try await ensureConnection(code: "", force: false)
            _ = try await roundTrip([
                "op": "result",
                "to_phone": toPhone,
                "to_mac": toMac,
            ])
        } catch {
            return
        }
    }

    static func changedCount(from before: [String: String], to after: [String: String]) -> Int {
        var count = 0
        var seen = Set<String>()
        for (key, value) in after {
            seen.insert(key)
            if before[key] != value {
                count += 1
            }
        }
        for key in before.keys where !seen.contains(key) {
            count += 1
        }
        return count
    }

    static func exchangeNotice(toPhone: Int, toMac: Int) -> String {
        var parts: [String] = []
        if toPhone > 0 {
            parts.append(exchangePhrase(toPhone, direction: "Desktop a Cellulare"))
        }
        if toMac > 0 {
            parts.append(exchangePhrase(toMac, direction: "Cellulare a Desktop"))
        }
        if parts.isEmpty {
            return "Scambio riuscito. Nessuna modifica."
        }
        return "Scambio riuscito. " + parts.joined(separator: " ")
    }

    private static func exchangePhrase(_ count: Int, direction: String) -> String {
        if count == 1 {
            return "1 registrazione aggiunta o modificata da \(direction)."
        }
        return "\(count) registrazioni aggiunte o modificate da \(direction)."
    }

    /// Il Desktop è aperto e non c'è più nulla da inviare: toglie l'avviso lasciato a programma chiuso.
    func clearPendingNotice() async -> Bool {
        do {
            try await ensureConnection(code: "", force: false)
            let reply = try await roundTrip(["op": "pending", "count": 0])
            return (reply["op"] as? String) == "pending_ok"
        } catch {
            return false
        }
    }

    /// Numero che cresce a ogni salvataggio del Mac. Non scarica l'elenco.
    func revision() async throws -> Int {
        try await ensureConnection(code: "", force: false)
        let reply = try await roundTrip(["op": "revision"])
        guard (reply["op"] as? String) == "revision_ok" else {
            throw ContiLanError.message(Self.errorText(reply) ?? "Il Desktop non risponde.")
        }
        return Self.intValue(reply["revision"])
    }

    func push(records: [[String: Any]]) async throws -> [String: Any] {
        try await ensureConnection(code: "", force: false)
        let reply = try await roundTrip(["op": "push", "records": records])
        guard (reply["op"] as? String) == "push_ok", let light = reply["light"] as? [String: Any] else {
            throw ContiLanError.message(Self.errorText(reply) ?? "Il Desktop non ha confermato il salvataggio.")
        }
        rememberRevision(reply)
        return light
    }

    private func rememberRevision(_ reply: [String: Any]) {
        confirmedRevision = Self.intValue(reply["revision"])
    }

    private static func intValue(_ value: Any?) -> Int {
        switch value {
        case let n as Int:
            return n
        case let n as NSNumber:
            return n.intValue
        default:
            return 0
        }
    }

    static func fingerprints(of db: [String: Any]) -> [String: String] {
        var out: [String: String] = [:]
        for rec in records(in: db) {
            let ident = identity(rec)
            if !ident.isEmpty {
                out[ident] = fingerprint(rec)
            }
        }
        return out
    }

    /// Righe nuove o diverse dall'ultimo colloquio. Se manca l'id del telefono, ne assegna uno.
    static func dirtyRecords(in db: inout [String: Any], baseline: [String: String]) -> [[String: Any]] {
        guard var years = db["years"] as? [[String: Any]] else { return [] }
        var dirty: [[String: Any]] = []
        for yi in years.indices {
            guard var recs = years[yi]["records"] as? [[String: Any]] else { continue }
            var changed = false
            for ri in recs.indices {
                var rec = recs[ri]
                let fp = fingerprint(rec)
                var ident = identity(rec)
                if !ident.isEmpty, baseline[ident] == fp {
                    continue
                }
                if text(rec["conti_light_record_id"]).isEmpty {
                    rec["conti_light_record_id"] = UUID().uuidString
                    recs[ri] = rec
                    changed = true
                    ident = identity(rec)
                }
                if !ident.isEmpty {
                    dirty.append(rec)
                }
            }
            if changed {
                years[yi]["records"] = recs
            }
        }
        db["years"] = years
        return dirty
    }

    /// Tiene le righe non ancora confermate dal Mac sopra l'elenco appena scaricato.
    static func applyingUnsent(
        _ pending: [String: Any],
        onto mac: [String: Any]
    ) -> (merged: [String: Any], unsent: [[String: Any]]) {
        var pendingDb = pending
        let unsent = dirtyRecords(in: &pendingDb, baseline: fingerprints(of: mac))
        guard !unsent.isEmpty else { return (mac, []) }
        var merged = mac
        var years = merged["years"] as? [[String: Any]] ?? []
        for rec in unsent {
            let ident = identity(rec)
            let yearNum = intValue(rec["year"])
            if let yi = years.firstIndex(where: { intValue($0["year"]) == yearNum }) {
                var recs = years[yi]["records"] as? [[String: Any]] ?? []
                if let ri = recs.firstIndex(where: { identity($0) == ident }) {
                    recs[ri] = rec
                } else {
                    recs.append(rec)
                }
                years[yi]["records"] = recs
            } else {
                years.append(["year": yearNum, "records": [rec]])
            }
        }
        merged["years"] = years
        return (merged, unsent)
    }

    private static let fingerprintKeys = [
        "year", "date_iso", "amount_eur", "note", "category_code",
        "account_primary_code", "account_secondary_code", "cheque", "is_cancelled",
    ]

    private static func records(in db: [String: Any]) -> [[String: Any]] {
        var out: [[String: Any]] = []
        let years = db["years"] as? [[String: Any]] ?? []
        for year in years {
            let recs = year["records"] as? [[String: Any]] ?? []
            out.append(contentsOf: recs)
        }
        return out
    }

    private static func identity(_ rec: [String: Any]) -> String {
        let rid = text(rec["conti_light_record_id"])
        if !rid.isEmpty { return "id:\(rid)" }
        let legacy = text(rec["legacy_registration_key"])
        if !legacy.isEmpty { return "leg:\(legacy)" }
        return ""
    }

    private static func fingerprint(_ rec: [String: Any]) -> String {
        fingerprintKeys.map { "\($0)=\(text(rec[$0]))" }.joined(separator: "|")
    }

    private static func text(_ value: Any?) -> String {
        switch value {
        case let s as String:
            return s
        case let b as Bool:
            return b ? "true" : "false"
        case let n as NSNumber:
            if CFGetTypeID(n) == CFBooleanGetTypeID() {
                return n.boolValue ? "true" : "false"
            }
            return n.stringValue
        default:
            return ""
        }
    }

    private func ensureConnection(code: String, force: Bool) async throws {
        if !force, ready, connection != nil, !keyText.isEmpty {
            return
        }
        connection?.cancel()
        connection = nil
        ready = false
        let endpoint = try await browse()
        let conn = NWConnection(to: endpoint, using: .tcp)
        connection = conn
        do {
            try await waitUntilReady(conn)
        } catch {
            ready = false
            connection = nil
            throw error
        }
        ready = true
        let paired = try await roundTrip(pairMessage(code: code), seal: false)
        guard (paired["op"] as? String) == "pair_ok" else {
            throw ContiLanError.message(Self.errorText(paired) ?? "Accoppiamento rifiutato.")
        }
        if let token = paired["token"] as? String, !token.isEmpty {
            savedToken = token
        }
        if let received = paired["fernet_key"] as? String, FernetDecryptor(keyFileContents: received) != nil {
            keyText = received
            storeKey(received)
        }
        guard !keyText.isEmpty else {
            throw ContiLanError.message("Il Desktop non ha consegnato la chiave.")
        }
    }

    private func storeKey(_ key: String) {
        UserDefaults.standard.set(key, forKey: keyDefaults)
        deleteKeychainKey()
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: keychainAccount,
            kSecValueData as String: Data(key.utf8),
        ]
        SecItemAdd(query as CFDictionary, nil)
    }

    private func readStoredKey() -> String {
        if let text = UserDefaults.standard.string(forKey: keyDefaults), !text.isEmpty {
            return text
        }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: keychainAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let text = String(data: data, encoding: .utf8) else {
            return ""
        }
        return text
    }

    private func deleteStoredKey() {
        UserDefaults.standard.removeObject(forKey: keyDefaults)
        deleteKeychainKey()
    }

    private func deleteKeychainKey() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: keychainAccount,
        ]
        SecItemDelete(query as CFDictionary)
    }

    private func pairMessage(code: String) -> [String: Any] {
        var msg: [String: Any] = ["op": "pair", "token": savedToken]
        let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            msg["code"] = trimmed
        }
        return msg
    }

    private func browse() async throws -> NWEndpoint {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<NWEndpoint, Error>) in
            let browser = NWBrowser(for: .bonjour(type: "_conticdc._tcp", domain: "local."), using: .tcp)
            let gate = NSLock()
            var done = false
            func finish(_ result: Result<NWEndpoint, Error>) {
                gate.lock()
                defer { gate.unlock() }
                guard !done else { return }
                done = true
                browser.cancel()
                switch result {
                case .success(let endpoint):
                    cont.resume(returning: endpoint)
                case .failure(let error):
                    cont.resume(throwing: error)
                }
            }
            browser.browseResultsChangedHandler = { results, _ in
                let home = results.first { result in
                    if case let .service(name, _, _, _) = result.endpoint {
                        return name == "Conti di casa"
                    }
                    return false
                }
                if let found = home {
                    finish(.success(found.endpoint))
                }
            }
            browser.stateUpdateHandler = { state in
                if case .failed(let error) = state {
                    finish(.failure(error))
                }
            }
            browser.start(queue: queue)
            queue.asyncAfter(deadline: .now() + 8) {
                finish(.failure(ContiLanError.message(
                    "Conti di casa non è in ascolto. Apri l'app sul Desktop, sulla stessa rete Wi-Fi. Al primo collegamento inserisci il codice."
                )))
            }
        }
    }

    private func waitUntilReady(_ conn: NWConnection) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            let gate = NSLock()
            var done = false
            func finish(_ result: Result<Void, Error>) {
                gate.lock()
                defer { gate.unlock() }
                guard !done else { return }
                done = true
                switch result {
                case .success:
                    cont.resume()
                case .failure(let error):
                    cont.resume(throwing: error)
                }
            }
            conn.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    finish(.success(()))
                case .failed(let error):
                    finish(.failure(error))
                default:
                    break
                }
            }
            conn.start(queue: queue)
            queue.asyncAfter(deadline: .now() + 8) {
                finish(.failure(ContiLanError.message("Il Desktop non risponde.")))
            }
        }
    }

    private func roundTrip(_ message: [String: Any], seal: Bool = true) async throws -> [String: Any] {
        let body = try jsonData(message)
        let wire: Data
        if seal {
            guard let encryptor = FernetEncryptor(keyFileContents: keyText) else {
                throw ContiLanError.message("Accoppiamento mancante.")
            }
            let token = try encryptor.encryptToUTF8String(plaintext: body)
            wire = try jsonData(["op": "sealed", "payload": token])
        } else {
            wire = body
        }
        var frame = Data(count: 4)
        let n = UInt32(wire.count)
        frame[0] = UInt8((n >> 24) & 0xff)
        frame[1] = UInt8((n >> 16) & 0xff)
        frame[2] = UInt8((n >> 8) & 0xff)
        frame[3] = UInt8(n & 0xff)
        frame.append(wire)
        let exchange = UUID()
        exchangeId = exchange
        queue.asyncAfter(deadline: .now() + 20) {
            Task { await self.expireExchange(exchange) }
        }
        do {
            try await send(frame)
            let header = try await receive(4)
            let bytes = [UInt8](header)
            let size = (Int(bytes[0]) << 24) | (Int(bytes[1]) << 16) | (Int(bytes[2]) << 8) | Int(bytes[3])
            guard size > 0, size <= 16 * 1024 * 1024 else {
                throw ContiLanError.message("Risposta del Desktop troppo grande.")
            }
            let payload = try await receive(size)
            guard var reply = try jsonObject(payload) else {
                throw ContiLanError.message("Risposta del Desktop illeggibile.")
            }
            if (reply["op"] as? String) == "sealed" {
                guard let decryptor = FernetDecryptor(keyFileContents: keyText) else {
                    throw ContiLanError.message("Accoppiamento mancante.")
                }
                let token = reply["payload"] as? String ?? ""
                let clear = try decryptor.decrypt(encFileContents: Data(token.utf8))
                guard let opened = try jsonObject(clear) else {
                    throw ContiLanError.message("Risposta del Desktop illeggibile.")
                }
                reply = opened
            }
            exchangeId = UUID()
            return reply
        } catch {
            ready = false
            connection?.cancel()
            connection = nil
            throw error
        }
    }

    private func expireExchange(_ id: UUID) {
        guard id == exchangeId else { return }
        ready = false
        connection?.cancel()
        connection = nil
    }

    private func send(_ data: Data) async throws {
        guard let connection else {
            throw ContiLanError.message("Nessun collegamento con il Desktop.")
        }
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error {
                    cont.resume(throwing: error)
                } else {
                    cont.resume()
                }
            })
        }
    }

    private func receive(_ count: Int) async throws -> Data {
        guard let connection else {
            throw ContiLanError.message("Nessun collegamento con il Desktop.")
        }
        var got = Data()
        while got.count < count {
            let chunk: Data = try await withCheckedThrowingContinuation { cont in
                connection.receive(minimumIncompleteLength: 1, maximumLength: count - got.count) { data, _, isComplete, error in
                    if let error {
                        cont.resume(throwing: error)
                        return
                    }
                    if let data, !data.isEmpty {
                        cont.resume(returning: data)
                        return
                    }
                    if isComplete {
                        cont.resume(throwing: ContiLanError.message("Il Desktop ha chiuso il collegamento."))
                        return
                    }
                    cont.resume(returning: Data())
                }
            }
            if chunk.isEmpty {
                throw ContiLanError.message("Il Desktop ha chiuso il collegamento.")
            }
            got.append(chunk)
        }
        return got
    }

    private func jsonData(_ obj: [String: Any]) throws -> Data {
        guard JSONSerialization.isValidJSONObject(obj),
              let data = try? JSONSerialization.data(withJSONObject: obj) else {
            throw ContiLanError.message("Registrazione non inviabile.")
        }
        return data
    }

    private func jsonObject(_ data: Data) throws -> [String: Any]? {
        let obj = try JSONSerialization.jsonObject(with: data)
        return obj as? [String: Any]
    }

    private static func errorText(_ reply: [String: Any]) -> String? {
        let text = reply["error"] as? String ?? ""
        return text.isEmpty ? nil : text
    }
}
