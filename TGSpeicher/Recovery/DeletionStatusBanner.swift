import SwiftUI

struct DeletionStatusBanner: View {
    @ObservedObject var cloud: CloudStore
    var body: some View {
        if cloud.isDeleting || !cloud.deletingFileIDs.isEmpty || cloud.deletionError != nil {
            HStack(spacing: 12) {
                if cloud.isDeleting { ProgressView() }
                else { Image(systemName: "exclamationmark.arrow.triangle.2.circlepath").foregroundStyle(.orange) }
                VStack(alignment: .leading, spacing: 3) {
                    Text(cloud.deletionStatus.isEmpty ? "Löschen nicht möglich" : cloud.deletionStatus)
                        .font(.subheadline.weight(.semibold))
                    if let error = cloud.deletionError { Text(error).font(.caption).foregroundStyle(.secondary).lineLimit(3) }
                }
                Spacer(minLength: 0)
                if !cloud.isDeleting {
                    Button("Erneut prüfen") { cloud.retryDeletions() }.buttonStyle(.bordered)
                        .disabled(!cloud.recoveryReady || cloud.isRefreshing)
                }
            }
            .padding(12)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
            .padding(.horizontal).padding(.top, 4)
        }
    }
}
