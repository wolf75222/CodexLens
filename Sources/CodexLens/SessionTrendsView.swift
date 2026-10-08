import AppKit
import Charts
import SwiftUI
import LensCore

/// A bounded presentation of the activity projection. The index owns counting,
/// deduplication and source IDs; selecting a mark never rereads a journal.
struct SessionTrendsView: View {
    @EnvironmentObject private var store: LensStore

    var body: some View {
        if let presentation = store.presentation {
            let sourceHome = store.observedSourceHome, openingID = store.openingIdentity
            SessionTrendContent(projection: presentation.trends,
                metric: $store.trendMetric, cumulative: $store.trendCumulative,
                selectedDate: Binding(get: { store.trendSelectedDate }, set: { date in
                    guard store.snapshot?.root.id == presentation.rootID, store.observedSourceHome == sourceHome,
                          store.openingIdentity == openingID else { return }
                    store.trendSelectedDate = date
                }), valuesVisible: $store.trendValuesVisible, preparing: store.isProjecting,
                inspect: { store.inspectTrendPeriod($0, rootID: presentation.rootID, sourceHome: sourceHome, openingID: openingID) },
                showCoverage: { store.showCoverage = true })
        } else if store.isProjecting {
            LensLoadingState(title: LensL10n.text("Préparation des courbes…"), workProgress: store.projectionProgress)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            LensCollectionEmptyState(title: LensL10n.text("Pas de données à tracer"),
                detail: LensL10n.text("Ouvrez une session pour consulter son activité."), symbol: "chart.xyaxis.line")
        }
    }
}

private struct SessionTrendContent: View {
    let projection: SessionTrendProjection
    @Binding var metric: SessionTrendMetric
    @Binding var cumulative: Bool
    @Binding var selectedDate: Date?
    @Binding var valuesVisible: Bool
    let preparing: Bool
    let inspect: (SessionTrendBucket) -> Void
    let showCoverage: () -> Void
    @FocusState private var chartFocused: Bool

    private var selectedBucket: SessionTrendBucket? {
        selectedDate.flatMap { projection.bucket(containing: $0) }
    }
    private var chartSelection: Binding<Date?> {
        Binding(get: {
            guard cumulative, let bucket = selectedBucket else { return selectedDate }
            return bucket.end
        }, set: { date in
            // Cumulative marks sit at interval ends. Keep the selected date
            // inside their half-open interval, including the final endpoint.
            selectedDate = date.flatMap { projection.selectionDate(at: $0, cumulative: cumulative) }
        })
    }
    private var locale: Locale { Locale(identifier: LensL10n.resolvedLanguage.rawValue) }
    private var plottedCount: Int {
        projection.totalCounts[metric, default: 0] - projection.unplottedCounts[metric, default: 0]
    }
    private var accent: Color { LensControlAccent.current.color }
    private var chartStyle: SessionTrendChartStyle { projection.chartStyle(for: metric, cumulative: cumulative) }

    var body: some View {
        VStack(spacing: 0) {
            controls.padding(.horizontal, 16).padding(.top, 12).padding(.bottom, 8)
            summary.padding(.horizontal, 16).padding(.bottom, 12)
            Divider()
            if projection.buckets.isEmpty {
                LensCollectionEmptyState(title: LensL10n.text("Pas de données datées"),
                    detail: LensL10n.text("Les éléments sans horodatage restent consultables dans l’activité, mais ne peuvent pas être placés sur une courbe."),
                    symbol: "clock.badge.questionmark")
            } else if plottedCount == 0 {
                LensCollectionEmptyState(title: LensL10n.text("Aucun élément pour cette mesure"),
                    detail: LensL10n.text("Choisissez une autre mesure ou ajustez les filtres de l’activité. Les éléments sans date ne sont pas tracés."),
                    symbol: "chart.xyaxis.line")
            } else if valuesVisible {
                VSplitView {
                    plotPanel.frame(minHeight: 230)
                    valuesTable.frame(minHeight: 110)
                }
            } else {
                plotPanel.frame(maxHeight: .infinity)
            }
            Divider()
            coverageFooter.padding(.horizontal, 16).padding(.vertical, 10)
        }
        .background(Color(nsColor: .textBackgroundColor))
        .accessibilityIdentifier("lens-session-trends")
    }

    private var controls: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                metricPicker
                Spacer(minLength: 8)
                countingPicker
                valuesButton
            }
            VStack(alignment: .leading, spacing: 8) {
                metricPicker
                HStack(spacing: 12) {
                    countingPicker
                    Spacer(minLength: 8)
                    valuesButton
                }
            }
        }
    }

    private var metricPicker: some View {
        Picker(LensL10n.text("Mesure"), selection: $metric) {
            ForEach(SessionTrendMetric.allCases) { item in
                Label(SessionTrendLabels.title(item), systemImage: SessionTrendLabels.symbol(item)).tag(item)
            }
        }
        .pickerStyle(.menu).labelsHidden()
        .frame(minWidth: 160, idealWidth: 240, maxWidth: 300, alignment: .leading)
        .accessibilityLabel(LensL10n.text("Mesure de la courbe"))
        .accessibilityIdentifier("lens-trends-metric")
        .help(SessionTrendLabels.detail(metric))
    }

    private var countingPicker: some View {
        Picker(LensL10n.text("Comptage"), selection: $cumulative) {
            Text(LensL10n.text("Par intervalle")).tag(false)
            Text(LensL10n.text("Cumul")).tag(true)
        }
        .pickerStyle(.segmented).labelsHidden().fixedSize().lensFilledControlAccent()
        .accessibilityLabel(LensL10n.text("Comptage par intervalle ou cumul"))
        .accessibilityIdentifier("lens-trends-counting")
        .help(LensL10n.text("Le cumul porte sur les données filtrées et datées, pas sur toute la session."))
    }

    private var valuesButton: some View {
        Button { valuesVisible.toggle() } label: {
            Image(systemName: "tablecells").foregroundStyle(valuesVisible ? accent : .secondary)
        }
        .buttonStyle(LensQuietButtonStyle())
        .accessibilityLabel(LensL10n.text(valuesVisible ? "Masquer les valeurs" : "Afficher les valeurs"))
        .accessibilityValue(LensL10n.text(valuesVisible ? "Affichées" : "Masquées"))
        .accessibilityIdentifier("lens-trends-values-toggle")
        .help(LensL10n.text("Afficher les valeurs dans un tableau accessible au clavier"))
        .disabled(projection.buckets.isEmpty || plottedCount == 0)
    }

    private var summary: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                Text(LensUI.count(plottedCount, singular: "élément daté", plural: "éléments datés"))
                    .font(LensUI.paneTitle).monospacedDigit()
                if preparing {
                    LensProgressIndicator(accessibilityLabel: LensL10n.text("Actualisation des courbes"))
                        .controlSize(.small)
                }
                Spacer(minLength: 8)
                if let width = projection.bucketWidth {
                    Text(LensL10n.text("Intervalles de {0}", intervalLabel(width)))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Text(SessionTrendLabels.detail(metric)).font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var plotPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            plot.frame(minHeight: 150, maxHeight: .infinity)
            selectionRow
        }
        .padding(.horizontal, 16).padding(.top, 20).padding(.bottom, 12)
    }

    private var plot: some View {
        Chart {
            if cumulative, let first = projection.buckets.first {
                LineMark(x: .value(LensL10n.text("Début de l’intervalle"), first.start),
                    y: .value(LensL10n.text("Cumul"), 0))
                    .foregroundStyle(accent).lineStyle(StrokeStyle(lineWidth: 2))
                    .interpolationMethod(.stepEnd).accessibilityHidden(true)
            }
            ForEach(projection.buckets) { bucket in
                if cumulative {
                    LineMark(x: .value(LensL10n.text("Fin de l’intervalle"), bucket.end),
                        y: .value(LensL10n.text("Cumul"), bucket.cumulativeCount(for: metric)))
                        .foregroundStyle(accent).lineStyle(StrokeStyle(lineWidth: 2))
                        .interpolationMethod(.stepEnd)
                        .accessibilityLabel(Text(periodLabel(bucket)))
                        .accessibilityValue(Text(valueLabel(bucket)))
                    if projection.buckets.count == 1 {
                        PointMark(x: .value(LensL10n.text("Fin de l’intervalle"), bucket.end),
                            y: .value(LensL10n.text("Cumul"), bucket.cumulativeCount(for: metric)))
                            .foregroundStyle(accent).symbolSize(25).accessibilityHidden(true)
                    }
                } else if chartStyle == .eventStems {
                    if bucket.count(for: metric) > 0 {
                        RuleMark(x: .value(LensL10n.text("Période"), midpoint(bucket)),
                            yStart: .value(LensL10n.text("Nombre"), 0),
                            yEnd: .value(LensL10n.text("Nombre"), bucket.count(for: metric)))
                            .foregroundStyle(accent.opacity(0.55)).lineStyle(StrokeStyle(lineWidth: 2))
                            .accessibilityHidden(true)
                        PointMark(x: .value(LensL10n.text("Période"), midpoint(bucket)),
                            y: .value(LensL10n.text("Nombre"), bucket.count(for: metric)))
                            .foregroundStyle(accent).symbolSize(selectedBucket?.id == bucket.id ? 45 : 25)
                            .accessibilityLabel(Text(periodLabel(bucket)))
                            .accessibilityValue(Text(valueLabel(bucket)))
                    }
                } else {
                    RectangleMark(xStart: .value(LensL10n.text("Début de l’intervalle"), bucket.start),
                        xEnd: .value(LensL10n.text("Fin de l’intervalle"), bucket.end),
                        yStart: .value(LensL10n.text("Nombre"), 0),
                        yEnd: .value(LensL10n.text("Nombre"), bucket.count(for: metric)))
                        .foregroundStyle(accent.opacity(selectedBucket?.id == bucket.id ? 0.95 : 0.62))
                        .accessibilityLabel(Text(periodLabel(bucket)))
                        .accessibilityValue(Text(valueLabel(bucket)))
                }
            }
            if let bucket = selectedBucket {
                if cumulative {
                    PointMark(x: .value(LensL10n.text("Période sélectionnée"), bucket.end),
                        y: .value(LensL10n.text("Cumul"), bucket.cumulativeCount(for: metric)))
                        .foregroundStyle(accent).symbolSize(45).accessibilityHidden(true)
                }
                RuleMark(x: .value(LensL10n.text("Période sélectionnée"), cumulative ? bucket.end : bucket.start.addingTimeInterval(bucket.end.timeIntervalSince(bucket.start) / 2)))
                    .foregroundStyle(accent).lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                    .annotation(position: .top, spacing: 6,
                        overflowResolution: .init(x: .fit(to: .chart), y: .disabled)) {
                        Text(displayedCount(bucket), format: .number.locale(locale))
                            .font(.caption.weight(.semibold)).monospacedDigit().foregroundStyle(.primary)
                    }
                    .accessibilityHidden(true)
            }
        }
        .chartXSelection(value: chartSelection)
        .chartGesture { proxy in
            SpatialTapGesture().onEnded { value in
                proxy.selectXValue(at: value.location.x)
                chartFocused = true
            }.simultaneously(with: DragGesture(minimumDistance: 3)
                .onChanged { value in
                    proxy.selectXValue(at: value.location.x)
                    chartFocused = true
                }
                .onEnded { value in proxy.selectXValue(at: value.location.x) })
        }
        .chartXScale(domain: plotDomain)
        .chartYScale(domain: .automatic(includesZero: true))
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 5)) { value in
                AxisGridLine().foregroundStyle(Color.secondary.opacity(0.13))
                AxisTick()
                AxisValueLabel {
                    if let date = value.as(Date.self) { Text(axisLabel(date)) }
                }
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(minimumStride: 1.0, desiredCount: 5)) { value in
                AxisGridLine().foregroundStyle(Color.secondary.opacity(0.13))
                AxisValueLabel {
                    if let count = value.as(Int.self) { Text(count, format: .number.locale(locale)) }
                    else if let count = value.as(Double.self) {
                        Text(count, format: .number.precision(.fractionLength(0)).locale(locale))
                    }
                }
            }
        }
        .chartXAxisLabel(LensL10n.text("Heure locale"), alignment: .trailing)
        .accessibilityLabel(LensL10n.text("Graphique : {0}", SessionTrendLabels.title(metric)))
        .accessibilityHint(LensL10n.text("Les valeurs sont aussi disponibles dans le tableau. Les flèches sélectionnent une période ; Retour ouvre son activité."))
        .accessibilityIdentifier("lens-trends-chart")
        .focusable()
        .focusEffectDisabled()
        .focused($chartFocused)
        .onChange(of: chartFocused) { _, focused in
            if focused && selectedBucket == nil { moveSelection(1) }
        }
        .onKeyPress(.leftArrow) { moveSelection(-1); return .handled }
        .onKeyPress(.rightArrow) { moveSelection(1); return .handled }
        .onKeyPress(.return) {
            guard let bucket = selectedBucket else { return .ignored }
            inspect(bucket); return .handled
        }
        .onKeyPress(.escape) { selectedDate = nil; chartFocused = false; return .handled }
    }

    private func midpoint(_ bucket: SessionTrendBucket) -> Date {
        bucket.start.addingTimeInterval(bucket.end.timeIntervalSince(bucket.start) / 2)
    }

    private var plotDomain: ClosedRange<Date> {
        // The projection supplies UTC-aligned, ordered, nonempty buckets.
        guard let first = projection.buckets.first, let last = projection.buckets.last else {
            return Date(timeIntervalSince1970: 0)...Date(timeIntervalSince1970: 1)
        }
        return first.start...last.end
    }

    private var selectionRow: some View {
        LensAdaptiveRow {
            if let bucket = selectedBucket {
                VStack(alignment: .leading, spacing: 3) {
                    Text(periodLabel(bucket)).font(LensUI.paneTitle)
                    Text(valueLabel(bucket)).font(.caption).foregroundStyle(.secondary).monospacedDigit()
                }
            } else {
                Text(LensL10n.text("Sélectionnez une période dans la courbe ou le tableau."))
                    .font(LensUI.metadata).foregroundStyle(.secondary)
            }
        } trailing: {
            Button(LensL10n.text("Voir l’activité")) {
                if let bucket = selectedBucket { inspect(bucket) }
            }
            .buttonStyle(.bordered).disabled(selectedBucket == nil)
            .accessibilityIdentifier("lens-trends-inspect-period")
            .help(LensL10n.text("Retrouver les événements de cette période sans perdre la sélection de la courbe"))
        }
    }

    private var valuesTable: some View {
        SessionTrendValuesTable(buckets: projection.buckets, metric: metric, selectedDate: $selectedDate,
            periodLabel: periodLabel, inspect: inspect)
        .accessibilityLabel(LensL10n.text("Valeurs de la courbe : {0}", SessionTrendLabels.title(metric)))
        .accessibilityIdentifier("lens-trends-values")
    }

    private var coverageFooter: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(LensL10n.text("Les filtres d’activité s’appliquent. Un intervalle vide peut ne pas avoir été observé."))
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if projection.unplottedCounts[metric, default: 0] > 0 {
                let count = projection.unplottedCounts[metric, default: 0]
                Text(LensL10n.text(count == 1 ? "{0} élément de cette mesure sans date exploitable" : "{0} éléments de cette mesure sans date exploitable", String(count)))
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if projection.unknownTimestampCount > 0 || projection.coverageLimitCount > 0 {
                LensAdaptiveRow {
                    if projection.unknownTimestampCount > 0 {
                        Text(LensL10n.text("Horodatage manquant pour {0} événements", String(projection.unknownTimestampCount)))
                            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                } trailing: {
                    if projection.coverageLimitCount > 0 {
                        Button { showCoverage() } label: {
                            Label(LensL10n.text("Limites des données"), systemImage: "info.circle")
                        }
                        .buttonStyle(LensQuietButtonStyle()).font(.caption)
                        .help(LensL10n.text("Consulter les limites des données chargées"))
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func displayedCount(_ bucket: SessionTrendBucket) -> Int {
        cumulative ? bucket.cumulativeCount(for: metric) : bucket.count(for: metric)
    }
    private func valueLabel(_ bucket: SessionTrendBucket) -> String {
        let count = displayedCount(bucket)
        let key = cumulative
            ? (count == 1 ? "{0} élément cumulé dans les données filtrées" : "{0} éléments cumulés dans les données filtrées")
            : (count == 1 ? "{0} élément dans cet intervalle" : "{0} éléments dans cet intervalle")
        return LensL10n.text(key, count.formatted(.number.locale(locale)))
    }
    private func periodLabel(_ bucket: SessionTrendBucket) -> String {
        let first = bucket.start.lensFormatted(date: .abbreviated, time: .standard)
        let last = bucket.end.lensFormatted(date: bucket.end.timeIntervalSince(bucket.start) >= 86400 ? .abbreviated : .omitted, time: .standard)
        return LensL10n.text("{0} – {1}", first, last)
    }
    private func axisLabel(_ date: Date) -> String {
        let width = projection.bucketWidth ?? 60
        if width >= 86400 { return date.formatted(.dateTime.locale(locale).day().month(.abbreviated)) }
        if width < 60 { return date.formatted(.dateTime.locale(locale).hour().minute().second()) }
        return date.formatted(.dateTime.locale(locale).hour().minute())
    }
    private func intervalLabel(_ seconds: TimeInterval) -> String {
        let amount: Double, unit: String
        if seconds >= 86400 { amount = seconds / 86400; unit = "{0} j" }
        else if seconds >= 3600 { amount = seconds / 3600; unit = "{0} h" }
        else if seconds >= 60 { amount = seconds / 60; unit = "{0} min" }
        else { amount = seconds; unit = "{0} s" }
        return LensL10n.text(unit, amount.formatted(.number.precision(.fractionLength(0...2)).locale(locale)))
    }
    private func moveSelection(_ direction: Int) {
        guard !projection.buckets.isEmpty else { return }
        if let id = selectedBucket?.id, let index = projection.buckets.firstIndex(where: { $0.id == id }) {
            let next = max(0, min(projection.buckets.count - 1, index + direction))
            selectedDate = projection.buckets[next].start
        } else {
            selectedDate = (direction > 0 ? projection.buckets.first : projection.buckets.last)?.start
        }
    }
}

private enum SessionTrendLabels {
    static func title(_ metric: SessionTrendMetric) -> String {
        switch metric {
        case .activity: return LensL10n.text("Événements")
        case .toolCalls: return LensL10n.text("Appels d’outils")
        case .mcpCalls: return LensL10n.text("Appels MCP")
        case .requestedFileChanges: return LensL10n.text("Modifications demandées")
        case .errors: return LensL10n.text("Erreurs signalées")
        case .waits: return LensL10n.text("Attentes enregistrées")
        case .compactions: return LensL10n.text("Compactages")
        }
    }
    static func detail(_ metric: SessionTrendMetric) -> String {
        switch metric {
        case .activity: return LensL10n.text("Événements datés de la sélection, sans doublons de sources.")
        case .toolCalls: return LensL10n.text("Appels enregistrés ; leur résultat ne compte pas comme un nouvel appel.")
        case .mcpCalls: return LensL10n.text("Appels MCP identifiés par leur nom d’outil, sans compter les mentions dans un script.")
        case .requestedFileChanges: return LensL10n.text("Un fichier ciblé compte une fois par appel et environnement. Consultez le résultat de chaque patch.")
        case .errors: return LensL10n.text("Erreurs signalées, regroupées quand les traces identifient le même appel.")
        case .waits: return LensL10n.text("Appels ou événements d’attente enregistrés, sans déduire les temps d’inactivité.")
        case .compactions: return LensL10n.text("Opérations de compactage identifiées ; leurs différentes traces ne sont comptées qu’une fois.")
        }
    }
    static func symbol(_ metric: SessionTrendMetric) -> String {
        switch metric {
        case .activity: return "waveform.path"
        case .toolCalls: return "wrench.and.screwdriver"
        case .mcpCalls: return "network"
        case .requestedFileChanges: return "plus.forwardslash.minus"
        case .errors: return "exclamationmark.triangle"
        case .waits: return "hourglass"
        case .compactions: return "archivebox"
        }
    }
}
