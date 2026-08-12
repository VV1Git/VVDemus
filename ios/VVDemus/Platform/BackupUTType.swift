import UniformTypeIdentifiers

extension UTType {
    /// The type of a `.vvdem` backup file, declared by this app.
    ///
    /// `exportedAs` rather than `importedAs` because VVDemus is the app that defines
    /// `com.vvdemus.backup` — it is declared in both targets' `UTExportedTypeDeclarations`
    /// (see `ios/project.yml`; the generated plists are written from scratch, so the
    /// declaration cannot live in them). Using `importedAs` for a type you own leaves the
    /// system with two competing declarations of the same identifier.
    ///
    /// A custom type rather than `.json`, even though a backup *is* JSON and conforms to
    /// `public.json` so Quick Look and any text editor can still open one: the import
    /// picker only enables files matching the types it is given, and `.json` would offer
    /// every JSON file on the device with no way to tell a backup from a config file until
    /// after it had been opened and rejected.
    static let vvdemBackup = UTType(exportedAs: "com.vvdemus.backup")
}
