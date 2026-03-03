import Foundation

struct MutationEnvelope<T: Codable & Sendable>: Codable, Sendable {
    let id: UUID
    let createdAt: Date
    let data: T

    init(id: UUID = UUID(), createdAt: Date = .now, data: T) {
        self.id = id
        self.createdAt = createdAt
        self.data = data
    }
}

struct CreateTransactionMutation: Codable, Sendable {
    let localTransactionID: UUID
    let payload: APICreateTransactionPayload
}

struct UpdateTransactionMutation: Codable, Sendable {
    let localTransactionID: UUID
    let remoteTransactionID: String
    let payload: APIUpdateTransactionPayload
}

struct DeleteTransactionMutation: Codable, Sendable {
    let localTransactionID: UUID
    let remoteTransactionID: String?
}

struct CreatePayeeMutation: Codable, Sendable {
    let proposedName: String
    let localTransactionID: UUID?
}
