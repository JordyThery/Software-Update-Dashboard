import JTKit

// The software update rules live in JTKit since 1.9.0 (`SoftwareUpdateRules`),
// shared with the other apps that report on updates. The app keeps calling
// them by the names it always had; `DeviceTarget` and `InspectInput` only
// for its tests.
typealias AppleDataUnavailable = SoftwareUpdateRules.AppleDataUnavailable
typealias BlueprintHealth = SoftwareUpdateRules.BlueprintHealth
typealias ClassificationContext = SoftwareUpdateRules.ClassificationContext
typealias Classifier = SoftwareUpdateRules.Classifier
typealias DeadlineZone = SoftwareUpdateRules.DeadlineZone
typealias DeadlineZones = SoftwareUpdateRules.DeadlineZones
typealias DeviceDetailText = SoftwareUpdateRules.DeviceDetailText
typealias DeviceInput = SoftwareUpdateRules.DeviceInput
typealias DeviceStatus = SoftwareUpdateRules.DeviceStatus
typealias DeviceTarget = SoftwareUpdateRules.DeviceTarget
typealias FirstPostings = SoftwareUpdateRules.FirstPostings
typealias InspectContext = SoftwareUpdateRules.InspectContext
typealias InspectFindings = SoftwareUpdateRules.InspectFindings
typealias InspectInput = SoftwareUpdateRules.InspectInput
typealias InspectResult = SoftwareUpdateRules.InspectResult
typealias InspectWorkflow = SoftwareUpdateRules.InspectWorkflow
typealias Plural = SoftwareUpdateRules.Plural
typealias PostingBasis = SoftwareUpdateRules.PostingBasis
typealias ReadinessCheck = SoftwareUpdateRules.ReadinessCheck
typealias RefreshProgress = SoftwareUpdateRules.RefreshProgress
typealias Replacement = SoftwareUpdateRules.Replacement
typealias ReportedDeadlines = SoftwareUpdateRules.ReportedDeadlines
typealias ServerTimeZoneCheck = SoftwareUpdateRules.ServerTimeZoneCheck
typealias StatusCategory = SoftwareUpdateRules.StatusCategory
typealias TargetRules = SoftwareUpdateRules.TargetRules
