/// Short durations for status text: `30 s`, `2 min`, `1 min 30 s`, `1 h`.
public enum DurationText {
    public static func short(_ duration: Duration) -> String {
        let total = Int((Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18).rounded())
        if total < 60 { return "\(total) s" }
        if total < 3600 {
            let minutes = total / 60, seconds = total % 60
            return seconds == 0 ? "\(minutes) min" : "\(minutes) min \(seconds) s"
        }
        let hours = total / 3600, minutes = (total % 3600) / 60
        return minutes == 0 ? "\(hours) h" : "\(hours) h \(minutes) min"
    }
}
