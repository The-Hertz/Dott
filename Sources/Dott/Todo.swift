import Foundation

/// Un compito della lista di Claude (TodoWrite o eventi Task).
struct TodoItem: Equatable, Identifiable {
    enum Status: String { case pending, inProgress = "in_progress", completed }
    let id: String
    var text: String
    var active: String?      // "sta scrivendo i test" (forma in corso)
    var status: Status
}

/// Ramo git del progetto e, se c'e', la sua pull request con lo stato della CI.
struct PRInfo: Equatable {
    var number: Int?
    var title: String?
    enum CI { case passing, failing, pending, none }
    var ci: CI
    var branch: String?
}
