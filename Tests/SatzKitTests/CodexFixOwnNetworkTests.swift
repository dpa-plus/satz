import Foundation
import Testing
@testable import SatzKit

// "An address on this network" (decision of 14.10.2026, after Codex's F14
// asked for a supported scheme and a host, and the first fix then allowed http
// to this computer only, which shut out a model server on the home network).
// Windows and Linux apply the same list (`desktop/src/core/browse.ts`).
//
// http may go to: this computer (localhost, 127.0.0.0/8, [::1]), a private or
// link-local address (10/8, 172.16/12, 192.168/16, 169.254/16, fc00::/7,
// fe80::/10), a host name without a dot ("nas"), a name ending in .local,
// .lan, .home.arpa or .internal. Everything else needs https.

private let audio = Data("RIFF....WAVEfmt fake audio bytes".utf8)

// MARK: - The list

private let onOwnNetwork = [
    // This computer.
    "http://localhost/v1", "http://LOCALHOST:8080/v1", "http://127.0.0.1:9000/v1", "http://127.0.0.2/v1", "http://127.255.255.254/v1",
    "http://[::1]:8080/v1", "http://[0:0:0:0:0:0:0:1]/v1",
    // Private and link-local IPv4, at both ends of every range.
    "http://10.0.0.1/v1", "http://10.255.255.255:8080/v1",
    "http://172.16.0.1/v1", "http://172.31.255.255/v1", "http://172.20.1.1:11434/v1",
    "http://192.168.0.1/v1", "http://192.168.1.20:11434/v1", "http://192.168.255.255/v1",
    "http://169.254.0.1/v1", "http://169.254.169.254/v1",
    // Unique local and link-local IPv6.
    "http://[fc00::1]/v1", "http://[fd12:3456:789a::1]:8080/v1", "http://[fdff:ffff::1]/v1",
    "http://[fe80::1]/v1", "http://[febf::1]:8080/v1", "http://[FE80::ABCD]/v1",
    // A host name without a dot.
    "http://nas/v1", "http://NAS:8000/v1", "http://my-nas/v1", "http://nas_2:8080/v1", "http://mac-mini/v1",
    // Names that exist inside a network only.
    "http://mac-mini.local:1234/v1", "http://NAS.LOCAL/v1", "http://whisper.lan/v1", "http://a.b.c.lan:9000/v1",
    "http://router.home.arpa/v1", "http://db.internal:8080/v1",
]

private let notOnOwnNetwork = [
    // Just outside every private range.
    "http://11.0.0.1/v1", "http://9.255.255.255/v1", "http://172.15.255.255/v1", "http://172.32.0.1/v1",
    "http://192.167.255.255/v1", "http://192.169.0.1/v1", "http://169.253.255.255/v1", "http://169.255.0.1/v1",
    "http://126.255.255.255/v1", "http://128.0.0.1/v1",
    // Public, shared address space (100.64/10 is not on the list), and "this host".
    "http://8.8.8.8/v1", "http://1.1.1.1/v1", "http://100.64.0.1/v1", "http://0.0.0.0/v1", "http://255.255.255.255/v1",
    // Spellings inet_aton would read as an address, which are names here, and names with dots are not local.
    "http://127.1/v1", "http://010.0.0.1/v1", "http://0x7f.0.0.1/v1", "http://192.168.1/v1", "http://10.1/v1",
    // A number alone has no dot, but is an address, not a name ("134744072" is 8.8.8.8).
    "http://134744072/v1", "http://2130706433/v1", "http://0x7f000001/v1", "http://0X08080808/v1",
    // IPv6 beside the two ranges.
    "http://[fbff::1]/v1", "http://[fec0::1]/v1", "http://[2001:db8::1]/v1", "http://[2606:4700::1111]/v1", "http://[::]/v1",
    "http://[::ffff:192.168.1.5]/v1", "http://[::ffff:7f00:1]/v1", "http://[::2]/v1",
    // Names that only contain or start like a local one.
    "http://example.com/v1", "http://localhost.example.com/v1", "http://127.0.0.1.example.com/v1", "http://192.168.1.5.example.com/v1",
    "http://nas.local.example.com/v1", "http://local.example.com/v1", "http://lan.example.com/v1", "http://internal.example.com/v1",
    "http://nas.locale/v1", "http://nas.landing/v1", "http://x.arpa/v1", "http://home.arpa/v1", "http://myhome.arpa/v1",
    "http://a.notlocal/v1", "http://nas.mylan/v1", "http://a.nothome.arpa/v1", "http://a.nointernal/v1",
    "http://10.0.0.1.nip.io/v1", "http://a..local/v1", "http://nas./v1", "http://localhost./v1",
    // The host is what comes after the @.
    "http://192.168.1.5@evil.example.com/v1", "http://192.168.1.5:80@evil.example.com/v1", "http://nas:pw@evil.example.com/v1",
    // Percent-encoding hides a dot from one reading and not from another.
    "http://192.168.1.5%2eevil.com/v1", "http://nas%2eexample.com/v1",
]

/// The address text with only what the host check looks at.
private func host(of text: String) -> String? {
    URL(string: text)?.host
}

@Suite(.serialized)
struct OwnNetworkTests {

    @Test(arguments: onOwnNetwork)
    func customTakesPlainHttpOnOwnNetwork(address: String) throws {
        #expect(ProviderReadiness.missing(.custom, hasKey: true, customBaseURL: address, model: "m").isEmpty, "\(address)")
        let checked = try #require(ProviderReadiness.sendableAddress(address), "\(address)")
        // What went through the check is what the request goes to.
        let settings = Transcriber.Settings(provider: .custom, model: "m", customBaseURL: URL(string: address))
        #expect(settings.baseURL == checked)
        #expect(settings.baseURL.host != "address-missing.invalid")
        let request = Transcriber(settings: settings).makeRequest(wav: audio, apiKey: "k")
        #expect(request.url?.absoluteString == checked.absoluteString + "/audio/transcriptions")
    }

    @Test(arguments: notOnOwnNetwork)
    func customRefusesPlainHttpAnywhereElse(address: String) {
        #expect(ProviderReadiness.missing(.custom, hasKey: true, customBaseURL: address, model: "m") == [.addressRefused], "\(address)")
        #expect(ProviderReadiness.sendableAddress(address) == nil)
        // The same text over https is fine: the key does not travel in the clear.
        let secure = address.replacingOccurrences(of: "http://", with: "https://")
        if !address.contains("%") {
            #expect(ProviderReadiness.sendableAddress(secure) != nil, "\(secure)")
        }
        // Nothing is sent: the settings hold the address that cannot exist.
        if let url = URL(string: address) {
            let settings = Transcriber.Settings(provider: .custom, model: "m", customBaseURL: url)
            #expect(settings.baseURL.host == "address-missing.invalid", "\(address) became \(settings.baseURL)")
        }
    }

    @Test(arguments: onOwnNetwork)
    func microsoftTakesPlainHttpOnOwnNetworkToo(address: String) throws {
        // Microsoft's own address is reduced to scheme, host and port.
        let url = try #require(MicrosoftSpeech.endpointURL(address), "\(address)")
        #expect(url.scheme == "http")
        #expect(url.host == URL(string: address)?.host)
        #expect(url.port == URL(string: address)?.port)
        #expect(ProviderReadiness.missing(.microsoft, hasKey: true, customBaseURL: "", model: "", microsoftEndpoint: address).isEmpty)
        let settings = Transcriber.Settings(provider: .microsoft, microsoftEndpoint: address)
        #expect(settings.baseURL == url)
    }

    @Test(arguments: notOnOwnNetwork)
    func microsoftRefusesPlainHttpAnywhereElse(address: String) {
        #expect(MicrosoftSpeech.endpointURL(address) == nil, "\(address)")
        #expect(ProviderReadiness.missing(.microsoft, hasKey: true, customBaseURL: "", model: "", microsoftEndpoint: address) == [.addressRefused])
        // The key does not go to the region's host instead.
        let settings = Transcriber.Settings(provider: .microsoft, microsoftRegion: "northeurope", microsoftEndpoint: address)
        #expect(settings.baseURL.host == "address-missing.invalid")
    }

    @Test(arguments: onOwnNetwork)
    func theHostRuleSaysTheSameAsTheAddressRule(address: String) {
        let name = host(of: address) ?? ""
        #expect(ProviderAddress.isOnOwnNetwork(name), "\(name)")
        #expect(ProviderAddress.allows(scheme: "http", host: name))
    }

    @Test func thisComputerIsTheWholeOfTheLoopbackRange() {
        for name in ["localhost", "LocalHost", "127.0.0.1", "127.1.2.3", "127.255.255.255", "::1", "[::1]"] {
            #expect(ProviderAddress.isThisComputer(name), "\(name)")
        }
        // Own network is not this computer.
        for name in ["10.0.0.1", "192.168.1.5", "nas", "nas.local", "fe80::1", "fd00::1", "8.8.8.8", "example.com", "", "128.0.0.1"] {
            #expect(!ProviderAddress.isThisComputer(name), "\(name)")
        }
    }

    @Test func httpsGoesAnywhereWithAHostAndNothingElseDoes() {
        for address in ["https://example.com/v1", "https://8.8.8.8/v1", "HTTPS://Example.com:8443/v1", "https://nas.local/v1", "https://[2001:db8::1]/v1"] {
            #expect(ProviderReadiness.sendableAddress(address) != nil, "\(address)")
        }
        // A host is required, and only these two schemes.
        for address in ["//nas/v1", "//192.168.1.5/v1", "ftp://nas/v1", "file://nas/tmp", "ws://nas/v1", "ssh://nas", "javascript:alert(1)",
                        "http://", "http:///v1", "https://", "https:///v1", "nas/v1", "nas:8080/v1", "192.168.1.5:8080/v1", "", " ", "http:// "] {
            #expect(ProviderReadiness.sendableAddress(address) == nil, "\(address)")
        }
        #expect(!ProviderAddress.allows(scheme: "http", host: ""))
        #expect(!ProviderAddress.allows(scheme: "https", host: ""))
        #expect(!ProviderAddress.allows(scheme: "ftp", host: "192.168.1.5"))
        #expect(!ProviderAddress.allows(scheme: "file", host: "localhost"))
    }

    @Test func aDottedNameIsNotMadeLocalByWhatItStartsWith() {
        for name in ["local", "lan", "internal", "nas"] {
            // Without a dot these are names of the network ("nas") and allowed...
            #expect(ProviderAddress.isOnOwnNetwork(name), "\(name)")
        }
        // ...but only as the end of a longer name, never in front of more.
        for name in ["local.com", "lan.net", "internal.org", "local.nas", "nas.local.net", ".local", "..lan", "x..internal"] {
            #expect(!ProviderAddress.isOnOwnNetwork(name), "\(name)")
        }
    }

    @Test(arguments: ["http://nas%2elocal/v1", "http://192%2e168%2e1%2e5/v1", "http://%6eas/v1", "http://mac-mini%2Elocal:1234/v1"])
    func aHostThatNeedsDecodingIsNotTakenForAnOwnNetworkNameOverHttp(address: String) {
        // Decoded these read as nas.local, 192.168.1.5, nas, mac-mini.local, and
        // Custom sends the text as typed, which the network stack need not read
        // the same way: the key would go to whatever it looks up instead.
        #expect(host(of: address).map(ProviderAddress.isOnOwnNetwork) == true, "decoded, \(address) is local")
        #expect(ProviderReadiness.sendableAddress(address) == nil, "\(address)")
        #expect(ProviderReadiness.missing(.custom, hasKey: true, customBaseURL: address, model: "m") == [.addressRefused])
    }

    @Test func aZoneOnALinkLocalAddressIsTheInterfaceNotTheHost() {
        #expect(ProviderAddress.isOnOwnNetwork("fe80::1%en0"))
        #expect(ProviderAddress.isOnOwnNetwork("[fe80::1%en0]"))
        #expect(!ProviderAddress.isOnOwnNetwork("2001:db8::1%en0"))
        #expect(ProviderReadiness.sendableAddress("http://[fe80::1%25en0]:8080/v1") != nil)
    }
}

// MARK: - What the user is told

@Suite(.serialized)
struct AddressWordingTests {

    private let why = (
        de: "Diese Adresse geht nicht: https, oder http nur im eigenen Netz.",
        en: "This address won't work: https, or http only on your own network."
    )

    @Test func aRefusedAddressSaysWhyAndAnEmptyOneStillAsksForIt() {
        #expect(ProviderReadiness.message([.addressRefused], in: .german) == why.de)
        #expect(ProviderReadiness.message([.addressRefused], in: .english) == why.en)
        // Nothing typed: the old words.
        #expect(ProviderReadiness.message([.address], in: .german) == "Erst die Adresse eintragen")
        #expect(ProviderReadiness.message([.address], in: .english) == "Enter the address first")
    }

    @Test func whatElseIsMissingComesFirstAndTheAddressIsStillTold() {
        #expect(ProviderReadiness.message([.key, .addressRefused], in: .german) == "Erst den Schlüssel eintragen. " + why.de)
        #expect(ProviderReadiness.message([.key, .addressRefused, .model], in: .german) == "Erst Schlüssel und Modell eintragen. " + why.de)
        #expect(ProviderReadiness.message([.key, .addressRefused, .model], in: .english) == "Enter the key and model first. " + why.en)
        #expect(ProviderReadiness.message([.addressRefused, .model], in: .english) == "Enter the model first. " + why.en)
    }

    @Test func theMessagesHaveNoEmDash() {
        for language in Language.allCases {
            for needs in [[ProviderReadiness.Need.addressRefused], [.key, .addressRefused, .model]] {
                #expect(ProviderReadiness.message(needs, in: language)?.contains("\u{2014}") == false)
            }
        }
    }

    @Test(arguments: [Provider.custom, .microsoft])
    func settingsAndSetupGetTheRefusalFromTheReadinessOfTheProvider(provider: Provider) {
        // Both views print `ProviderReadiness.message(needs)`; this is what they get.
        let needs = ProviderReadiness.missing(provider, hasKey: true, customBaseURL: "http://example.com/v1", model: "m",
                                              microsoftEndpoint: "http://example.com")
        #expect(needs == [.addressRefused])
        #expect(ProviderReadiness.message(needs, in: .german) == why.de)
        let empty = ProviderReadiness.missing(provider, hasKey: true, customBaseURL: "", model: "m", microsoftEndpoint: "")
        #expect(empty == (provider == .custom ? [.address] : []))
    }

    @Test func anAddressNeedConcernsTheAddress() {
        #expect(ProviderReadiness.Need.address.concernsAddress)
        #expect(ProviderReadiness.Need.addressRefused.concernsAddress)
        #expect(!ProviderReadiness.Need.key.concernsAddress && !ProviderReadiness.Need.model.concernsAddress)
    }
}
