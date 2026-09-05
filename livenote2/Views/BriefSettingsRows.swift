import SwiftUI

/// Settings > Meetings 에 표시되는 브리핑 설정 행.
struct BriefSettingsRows: View {
    @Bindable var controller: BriefingController

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle("Enable pre-meeting briefs", isOn: $controller.settings.enabled)

            if controller.settings.enabled {
                HStack {
                    Text("Morning batch generation")
                    Spacer()
                    Picker("", selection: $controller.settings.batchHour) {
                        ForEach(5...10, id: \.self) { hour in
                            Text(String(format: "%02d:00", hour)).tag(hour)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 90)
                }

                Toggle("Skip meetings with 8+ attendees", isOn: $controller.settings.skipLargeMeetings)
            }
        }
    }
}
