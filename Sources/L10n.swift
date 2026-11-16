import Foundation

// Traducción: las claves son los textos en español; las traducciones viven en
// Resources/<idioma>.lproj/Localizable.strings y macOS elige según el idioma del sistema
// (o el definido para Pulso en Ajustes del Sistema › General › Idioma y región).

/// Texto traducido al idioma activo.
func L(_ key: String) -> String {
    NSLocalizedString(key, comment: "")
}

/// Texto traducido con argumentos al estilo printf (%@, %ld, %.2f…).
func L(_ key: String, _ args: CVarArg...) -> String {
    String(format: NSLocalizedString(key, comment: ""), locale: Locale.current, arguments: args)
}
