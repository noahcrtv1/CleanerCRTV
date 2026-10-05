import SwiftUI

/// Telas da barra lateral.
enum Feature: String, CaseIterable, Identifiable, Hashable {
    case dashboard, cleanup, largeOld, duplicates, diskMap, uninstaller, optimize, monitor, history

    var id: String { rawValue }

    var title: String {
        switch self {
        case .dashboard: "Painel"
        case .cleanup: "Lixo do sistema"
        case .largeOld: "Grandes e antigos"
        case .duplicates: "Duplicados"
        case .diskMap: "Mapa do disco"
        case .uninstaller: "Desinstalador"
        case .optimize: "Otimização"
        case .monitor: "Monitor"
        case .history: "Histórico"
        }
    }

    var subtitle: String {
        switch self {
        case .dashboard: "Escaneamento inteligente: lixo, arquivos esquecidos e o que pesa no seu Mac"
        case .cleanup: "Caches, registros, restos de desenvolvimento e downloads esquecidos"
        case .largeOld: "Arquivos enormes ou que você não abre há muito tempo"
        case .duplicates: "Cópias idênticas do mesmo arquivo, conferidas byte a byte"
        case .diskMap: "Veja o que ocupa espaço, pasta por pasta"
        case .uninstaller: "Remova apps por completo, com preferências, caches e restos"
        case .optimize: "Itens de início, agentes em segundo plano e manutenção"
        case .monitor: "Processador, memória, disco e rede em tempo real"
        case .history: "Tudo o que o CleanerCRTV já removeu"
        }
    }

    var symbol: String {
        switch self {
        case .dashboard: "sparkles"
        case .cleanup: "bubbles.and.sparkles"
        case .largeOld: "doc.text.magnifyingglass"
        case .duplicates: "doc.on.doc"
        case .diskMap: "chart.pie"
        case .uninstaller: "xmark.app"
        case .optimize: "speedometer"
        case .monitor: "waveform.path.ecg"
        case .history: "clock.arrow.circlepath"
        }
    }

    var tint: Color {
        switch self {
        case .dashboard: Brand.violet
        case .cleanup: Brand.teal
        case .largeOld: Brand.orange
        case .duplicates: Brand.magenta
        case .diskMap: Brand.violet
        case .uninstaller: Brand.red
        case .optimize: Brand.green
        case .monitor: Brand.teal
        case .history: .gray
        }
    }

    var section: FeatureSection {
        switch self {
        case .dashboard: .general
        case .cleanup, .largeOld, .duplicates: .cleaning
        case .diskMap: .space
        case .uninstaller: .apps
        case .optimize, .monitor: .speed
        case .history: .log
        }
    }
}

enum FeatureSection: String, CaseIterable, Identifiable {
    case general, cleaning, space, apps, speed, log

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: "Geral"
        case .cleaning: "Limpeza"
        case .space: "Espaço"
        case .apps: "Aplicativos"
        case .speed: "Desempenho"
        case .log: "Registro"
        }
    }

    var features: [Feature] { Feature.allCases.filter { $0.section == self } }
}

/// Contrato comum dos módulos que varrem o disco (o Painel dispara e lê todos por aqui).
@MainActor
protocol ScanningFeature: AnyObject {
    var isScanning: Bool { get }
    /// Texto curto ao lado do item na barra lateral (ex.: "3,2 GB"). nil = sem selo.
    var badge: String? { get }
    func scan() async
    func cancel()
}
