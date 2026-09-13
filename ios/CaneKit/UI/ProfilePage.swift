//
//  ProfilePage.swift
//  CaneKit
//
//  Profile, Apple Health-style Medical ID card, and mobility fitness tracking.
//  Provides emergency medical identification for first responders (white cane user status,
//  blood type, allergies, medications, emergency contacts, residence) and daily mobility
//  metrics (steps, distance walked, active time, trips completed).
//
//  Owner: `ContentView.page` switch (tab `.profile`).
//  Module `ui-views` in docs/CODE_REFERENCE.md.
//

import SwiftUI

/// Profile page: Emergency Medical ID card, mobility fitness stats, and profile editor.
struct ProfilePage: View {
    @Environment(AppModel.self) private var model
    @State private var showingEditor = false
    @State private var showingShareSheet = false

    var body: some View {
        pageScroll {
            medicalIDCard
            mobilityFitnessCard
        }
        .sheet(isPresented: $showingEditor) {
            EditMedicalIDSheet(store: model.medicalProfile)
        }
    }

    // MARK: - Medical ID Card

    private var medicalIDCard: some View {
        let p = model.medicalProfile.profile
        return CKCard(title: "EMERGENCY MEDICAL ID") {
            // Profile Header
            HStack(spacing: CKSpacing.md) {
                #if canImport(UIKit)
                if let uiImage = UIImage(named: "AritroProfile") {
                    Image(uiImage: uiImage)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 56, height: 56)
                        .clipShape(Circle())
                        .overlay(Circle().stroke(CKColor.accent, lineWidth: 2))
                        .accessibilityLabel("Profile photo of \(p.name)")
                } else {
                    Image(systemName: "person.crop.circle.fill")
                        .font(.system(size: 52))
                        .foregroundStyle(CKColor.accent)
                }
                #else
                Image(systemName: "person.crop.circle.fill")
                    .font(.system(size: 52))
                    .foregroundStyle(CKColor.accent)
                #endif

                VStack(alignment: .leading, spacing: CKSpacing.xs) {
                    Text(p.name)
                        .font(CKFont.instruction)
                        .foregroundStyle(CKColor.textPrimary)

                    HStack(spacing: CKSpacing.xs) {
                        Image(systemName: "staroflife.fill")
                            .font(.subheadline)
                            .foregroundStyle(CKColor.danger)
                        Text("EMERGENCY ID")
                            .font(CKFont.pill)
                            .foregroundStyle(CKColor.danger)
                    }
                }

                Spacer()

                Button {
                    showingEditor = true
                } label: {
                    Text("Edit")
                        .font(CKFont.secondary.weight(.semibold))
                        .foregroundStyle(CKColor.accent)
                        .padding(.horizontal, CKSpacing.md)
                        .padding(.vertical, CKSpacing.xs)
                        .background(CKColor.surfaceRaised, in: Capsule())
                }
                .accessibilityLabel("Edit Medical ID")
            }

            // High-visibility Emergency Alert Banner
            HStack(alignment: .top, spacing: CKSpacing.md) {
                Image(systemName: "exclamationmark.shield.fill")
                    .font(.title2)
                    .foregroundStyle(CKColor.danger)

                VStack(alignment: .leading, spacing: CKSpacing.xs) {
                    Text("WHITE CANE USER / BLIND")
                        .font(CKFont.pill)
                        .foregroundStyle(CKColor.danger)
                    Text(p.emergencyNotes)
                        .font(CKFont.secondary)
                        .foregroundStyle(CKColor.textPrimary)
                }
            }
            .padding(CKSpacing.md)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(CKColor.surfaceRaised, in: RoundedRectangle(cornerRadius: CKRadius.button))

            // Medical Details Grid
            VStack(spacing: CKSpacing.sm) {
                infoRow(label: "Date of Birth", value: p.dateOfBirth, icon: "calendar")
                infoRow(label: "Blood Type", value: p.bloodType, icon: "drop.fill")
                infoRow(label: "Height & Weight", value: "\(p.height) · \(p.weight)", icon: "ruler.fill")
                infoRow(label: "Allergies", value: p.allergies, icon: "exclamationmark.triangle.fill")
                infoRow(label: "Medications", value: p.medications, icon: "pills.fill")
                infoRow(label: "Residence", value: p.homeAddress, icon: "house.fill")
                infoRow(label: "Cane Spec", value: p.caneType, icon: "figure.walk")
            }

            // Emergency Contact Row
            VStack(alignment: .leading, spacing: CKSpacing.xs) {
                Text("EMERGENCY CONTACT")
                    .font(CKFont.pill)
                    .foregroundStyle(CKColor.textSecondary)

                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(p.emergencyContactName)
                            .font(CKFont.label)
                            .foregroundStyle(CKColor.textPrimary)
                        Text("\(p.emergencyContactRelation) · \(p.emergencyContactPhone)")
                            .font(CKFont.secondary)
                            .foregroundStyle(CKColor.textSecondary)
                    }

                    Spacer()

                    if let phoneURL = URL(string: "tel:\(p.emergencyContactPhone.filter { $0.isNumber || $0 == "+" })") {
                        Link(destination: phoneURL) {
                            HStack(spacing: CKSpacing.xs) {
                                Image(systemName: "phone.fill")
                                Text("Call")
                            }
                            .font(CKFont.pill)
                            .padding(.horizontal, CKSpacing.md)
                            .padding(.vertical, CKSpacing.sm)
                            .background(CKColor.accent, in: Capsule())
                            .foregroundStyle(CKColor.ink)
                        }
                        .accessibilityLabel("Call emergency contact \(p.emergencyContactName)")
                    }
                }
                .padding(CKSpacing.md)
                .background(CKColor.surfaceRaised, in: RoundedRectangle(cornerRadius: CKRadius.button))
            }

            // Spoken Summary Button
            CKBigButton(
                title: "Announce Medical ID",
                systemImage: "speaker.wave.2.fill",
                role: .secondary,
                hint: "Reads emergency medical identification aloud"
            ) {
                let summary = "\(p.name). White cane user, legally blind. Blood type \(p.bloodType). Allergies: \(p.allergies). Emergency contact: \(p.emergencyContactName), \(p.emergencyContactPhone)."
                // `.scene`, not `.obstacle` (Step 47 audit): this is a user-requested paragraph,
                // and `.obstacle` is the hazard band of AGENTS.md hard rule 8 / design.md §5.1 —
                // an obstacle name or a route line must be able to cut it, never the reverse.
                model.speech.say(summary, .scene, ttl: 20)
            }
        }
    }

    // MARK: - Mobility & Fitness Card

    private var mobilityFitnessCard: some View {
        let stats = model.medicalProfile.mobilityStats
        let activeSteps = stats.todaySteps > 0 ? stats.todaySteps : (model.trip.steps ?? 0)
        let activeDistKm = stats.todayDistanceMeters > 0 ? (stats.todayDistanceMeters / 1000.0) : (model.trip.distanceM / 1000.0)

        return CKCard(title: "MOBILITY & FITNESS") {
            HStack {
                Text("Today's Cane Mobility")
                    .font(CKFont.instruction)
                    .foregroundStyle(CKColor.textPrimary)

                Spacer()

                Button {
                    model.medicalProfile.refreshMobilityStats()
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.title3)
                        .foregroundStyle(CKColor.accent)
                }
                .accessibilityLabel("Refresh mobility stats")
            }

            // Large Glanceable Metrics
            HStack(spacing: CKSpacing.md) {
                metricTile(
                    title: "Steps Today",
                    value: "\(activeSteps.formatted())",
                    icon: "shoeprints.fill"
                )

                metricTile(
                    title: "Distance",
                    value: String(format: "%.1f km", activeDistKm),
                    icon: "figure.walk"
                )
            }

            HStack(spacing: CKSpacing.md) {
                metricTile(
                    title: "Trips Finished",
                    value: "\(stats.completedTrips)",
                    icon: "flag.checkered"
                )

                let paceMps = stats.averagePaceMps > 0 ? stats.averagePaceMps : 1.2
                metricTile(
                    title: "Average Pace",
                    value: String(format: "%.1f m/s", paceMps),
                    icon: "speedometer"
                )
            }

            // Active Route Live Telemetry
            if model.nav.isNavigating {
                VStack(alignment: .leading, spacing: CKSpacing.xs) {
                    Text("ACTIVE ROUTE")
                        .font(CKFont.pill)
                        .foregroundStyle(CKColor.accent)

                    HStack {
                        Text(model.nav.route?.name ?? "Current Walk")
                            .font(CKFont.label)
                            .foregroundStyle(CKColor.textPrimary)
                        Spacer()
                        Text("\(Int(model.trip.elapsed / 60)) min elapsed")
                            .font(CKFont.secondary)
                            .foregroundStyle(CKColor.textSecondary)
                    }
                }
                .padding(CKSpacing.md)
                .background(CKColor.surfaceRaised, in: RoundedRectangle(cornerRadius: CKRadius.button))
            }
        }
    }

    // MARK: - Helpers

    private func infoRow(label: String, value: String, icon: String) -> some View {
        HStack(spacing: CKSpacing.md) {
            Image(systemName: icon)
                .font(.body)
                .foregroundStyle(CKColor.textSecondary)
                .frame(width: 24)

            Text(label)
                .font(CKFont.body)
                .foregroundStyle(CKColor.textSecondary)

            Spacer()

            Text(value)
                .font(CKFont.body.weight(.medium))
                .foregroundStyle(CKColor.textPrimary)
                .multilineTextAlignment(.trailing)
        }
        .padding(.vertical, 4)
    }

    private func metricTile(title: String, value: String, icon: String) -> some View {
        VStack(alignment: .leading, spacing: CKSpacing.xs) {
            HStack(spacing: CKSpacing.xs) {
                Image(systemName: icon)
                    .font(.caption)
                    .foregroundStyle(CKColor.textSecondary)
                Text(title)
                    .font(CKFont.pill)
                    .foregroundStyle(CKColor.textSecondary)
            }

            Text(value)
                .font(CKFont.hero(28))
                .foregroundStyle(CKColor.textPrimary)
        }
        .padding(CKSpacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(CKColor.surfaceRaised, in: RoundedRectangle(cornerRadius: CKRadius.button))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title): \(value)")
    }
}

// MARK: - Edit Medical ID Sheet

struct EditMedicalIDSheet: View {
    @Environment(\.dismiss) private var dismiss
    var store: MedicalProfileStore

    @State private var name: String = ""
    @State private var emergencyNotes: String = ""
    @State private var dateOfBirth: String = ""
    @State private var bloodType: String = ""
    @State private var height: String = ""
    @State private var weight: String = ""
    @State private var allergies: String = ""
    @State private var medications: String = ""
    @State private var homeAddress: String = ""
    @State private var emergencyContactName: String = ""
    @State private var emergencyContactPhone: String = ""
    @State private var emergencyContactRelation: String = ""
    @State private var caneType: String = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("Identity") {
                    TextField("Full Name", text: $name)
                    TextField("Emergency Notes", text: $emergencyNotes)
                    TextField("Date of Birth", text: $dateOfBirth)
                    TextField("Home Address", text: $homeAddress)
                }

                Section("Medical Vitals") {
                    TextField("Blood Type", text: $bloodType)
                    TextField("Height", text: $height)
                    TextField("Weight", text: $weight)
                    TextField("Allergies", text: $allergies)
                    TextField("Medications", text: $medications)
                }

                Section("Emergency Contact") {
                    TextField("Contact Name", text: $emergencyContactName)
                    TextField("Relationship", text: $emergencyContactRelation)
                    TextField("Phone Number", text: $emergencyContactPhone)
                }

                Section("Cane Equipment") {
                    TextField("Cane Type", text: $caneType)
                }
            }
            .navigationTitle("Edit Medical ID")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        saveChanges()
                        dismiss()
                    }
                    .fontWeight(.bold)
                }
            }
            .onAppear {
                let p = store.profile
                name = p.name
                emergencyNotes = p.emergencyNotes
                dateOfBirth = p.dateOfBirth
                bloodType = p.bloodType
                height = p.height
                weight = p.weight
                allergies = p.allergies
                medications = p.medications
                homeAddress = p.homeAddress
                emergencyContactName = p.emergencyContactName
                emergencyContactPhone = p.emergencyContactPhone
                emergencyContactRelation = p.emergencyContactRelation
                caneType = p.caneType
            }
        }
    }

    private func saveChanges() {
        var p = store.profile
        p.name = name
        p.emergencyNotes = emergencyNotes
        p.dateOfBirth = dateOfBirth
        p.bloodType = bloodType
        p.height = height
        p.weight = weight
        p.allergies = allergies
        p.medications = medications
        p.homeAddress = homeAddress
        p.emergencyContactName = emergencyContactName
        p.emergencyContactPhone = emergencyContactPhone
        p.emergencyContactRelation = emergencyContactRelation
        p.caneType = caneType
        store.profile = p
    }
}
