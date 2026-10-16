import AppKit
import SwiftUI
import GridCore

struct OverviewView: View {
    @ObservedObject var model: AppModel
    @State private var displayID: String
    @State private var movingSpace: String?
    @State private var mergingSpace: String?
    @State private var movingWindow: WindowIdentity?
    @State private var detail: Space?
    init(model: AppModel) {
        self.model = model
        let displays = model.desktop?.displays ?? []
        let target = displays.first { $0.id == model.targetDisplay() } ?? displays.first
        _displayID = State(initialValue:target?.id ?? "")
    }
    private var displays: [Display] {
        let all = model.desktop?.displays ?? []
        return displayID == "all" ? all : all.filter { $0.id == displayID }
    }
    var body: some View {
        VStack(spacing:8) {
            HStack(spacing:10) {
                Image(systemName:"square.grid.3x3").foregroundStyle(.secondary)
                if (model.desktop?.displays.count ?? 0) > 1 {
                    Menu {
                        ForEach(model.desktop?.displays ?? [],id: \.id) { display in
                            Button(display.builtin ? "MacBook" : display.name) { displayID = display.id }
                        }
                        Button("Ambas pantallas") { displayID = "all" }
                    } label: { Text(displayID == "all" ? "Ambas pantallas" : displays.first.map { $0.builtin ? "MacBook" : $0.name } ?? "Tus espacios").lineLimit(1) }
                        .menuStyle(.borderlessButton).fixedSize()
                } else { Text("Tus espacios").font(.subheadline.weight(.medium)) }
                Spacer()
                Button { model.undoOrganization() } label: { Image(systemName:"arrow.uturn.backward").frame(width:28,height:26).contentShape(Rectangle()) }
                    .disabled(model.state.dynamicMap?.undo.isEmpty != false).help("Deshacer organización")
                Button { model.closeOverview?(true) } label: { Image(systemName:"xmark").frame(width:26,height:26).contentShape(Rectangle()) }.help("Cerrar")
            }.buttonStyle(.plain)
            if movingSpace != nil || movingWindow != nil || mergingSpace != nil {
                HStack {
                    Text(mergingSpace != nil ? "Elegí dónde fusionar; vas a ver el resultado antes de confirmar" : "Elegí un destino o un + en el mapa").font(.caption)
                    Spacer(); Button("Cancelar") { cancelSelection() }
                }.padding(8).background(.tint.opacity(0.1),in:RoundedRectangle(cornerRadius:8))
            }
            ScrollView([.horizontal,.vertical]) {
                HStack(alignment:.top,spacing:20) {
                    ForEach(displays,id: \.id) { display in
                        VStack(alignment:.leading,spacing:8) {
                            if displays.count > 1 { Label(display.builtin ? "MacBook" : display.name,systemImage:"display").font(.caption.weight(.medium)).foregroundStyle(.secondary) }
                            SpatialBoardView(model:model,display:display,unit:MapPresentation.unit,editable:true,
                                open: { space in select(space,on:display) },
                                menu: { space in AnyView(spaceMenu(space)) },
                                vacancy: { row,column in
                                    if let movingSpace { model.setSpaceRect(movingSpace,SpaceRect(row:row,column:column,width:model.projectedSpaces.first { $0.id == movingSpace }?.rect.width ?? 1,height:model.projectedSpaces.first { $0.id == movingSpace }?.rect.height ?? 1),displayID:display.id) }
                                    else { model.createSpaceAt(row:row,column:column,moving:movingWindow,displayID:display.id) }
                                    cancelSelection()
                                })
                        }
                    }
                }.padding(0)
            }.scrollIndicators(.hidden).defaultScrollAnchor(.topLeading)
            HStack {
                Text(model.organizationError ?? (model.backendReady ? "Agarrá ⠿ para mover un espacio · Soltá en un borde para insertarlo" : model.message))
                    .font(.caption2).foregroundStyle(model.backendReady ? .secondary : Color.orange).lineLimit(2)
                Spacer()
                if let display = displays.first { Button { model.createSpace(displayID:display.id) } label: { Image(systemName:"plus") }.help("Nuevo espacio") }
            }
        }.padding(10).frame(minWidth:300,minHeight:180)
            .background(MapGlass())
            .onAppear { if let target = model.targetDisplay(), model.desktop?.displays.contains(where: { $0.id == target }) == true { displayID = target } }
            .onChange(of:model.desktop?.topology) { cancelSelection(); displayID = model.targetDisplay() ?? model.desktop?.displays.first?.id ?? "" }
            .onAppear { model.resizeOverview?(preferredSize) }
            .onChange(of:preferredSize) { model.resizeOverview?(preferredSize) }
            .onChange(of:isEditing) { model.editingOrganization = isEditing }
            .onChange(of:model.organizationWindowToMove) { if let window = model.organizationWindowToMove { movingWindow = window; model.organizationWindowToMove = nil } }
            .onDisappear { model.endDrag(); model.editingOrganization = false }
            .sheet(item:$detail) { space in LayoutEditorView(model:model,space:space,close:{ detail = nil }) }
            .sheet(item:$model.mergePreview) { MergePreviewView(model:model,preview:$0) }
            .sheet(item:$model.reunitePreview) { preview in
                VStack(spacing:16) {
                    Text("Reunir \(preview.name)").font(.headline)
                    MiniLayoutView(snapshot:preview.result,windows:preview.windows).frame(width:460,height:210)
                    Text("Se recupera la distribución original. Los espacios derivados se retiran.").font(.caption)
                    HStack { Button("Cancelar") { model.reunitePreview = nil }; Button("Reunir") { model.reunite(preview) } }
                }.padding(24)
            }
    }
    private var preferredSize:CGSize { MapPresentation.panelSize(displays:displays,model:model,editable:true) }
    private var isEditing: Bool { detail != nil || movingSpace != nil || movingWindow != nil || mergingSpace != nil || model.mergePreview != nil || model.reunitePreview != nil }
    private func cancelSelection() { movingSpace = nil; movingWindow = nil; mergingSpace = nil }
    private func select(_ space: Space,on display: Display) {
        if let source = movingSpace { model.moveSpace(source,to:space.id); cancelSelection() }
        else if let window = movingWindow { model.moveWindow(window,to:space.id); cancelSelection() }
        else if let source = mergingSpace { model.prepareMerge(source,into:space.id); cancelSelection() }
        else { model.openSpace(space.id,displayID:display.id) }
    }
    private func spaceMenu(_ space: Space) -> some View {
        Group {
            Button("Mover espacio…") { movingSpace = space.id }
            if space.nativeWindow == nil { Button("Editar distribución…") { detail = space } }
            if (model.desktop?.displays.count ?? 0) > 1 {
                Menu("Asignar a pantalla") {
                    ForEach(model.desktop?.displays ?? [],id: \.id) { display in Button(display.builtin ? "MacBook" : display.name) { model.assignSpace(space.id,displayID:display.id) } }
                }
            }
            if space.nativeWindow == nil && !model.windows(in:space).isEmpty { Button("Fusionar con…") { mergingSpace = space.id } }
            if let family = model.state.dynamicMap?.families.first(where: { $0.sourceID == space.id || $0.childIDs.contains(space.id) }) {
                Button("Reunir grupo…") { model.prepareReunite(family.sourceID) }
            }
            Menu("Tamaño del espacio") {
                Button("Más ancho") { var rect = space.rect; rect.width += 1; model.setSpaceRect(space.id,rect) }
                Button("Más alto") { var rect = space.rect; rect.height += 1; model.setSpaceRect(space.id,rect) }
                Button("Menos ancho") { var rect = space.rect; rect.width = max(1,rect.width-1); model.setSpaceRect(space.id,rect) }
                Button("Menos alto") { var rect = space.rect; rect.height = max(1,rect.height-1); model.setSpaceRect(space.id,rect) }
            }
            if model.windows(in:space).isEmpty { Button("Eliminar vacío",role:.destructive) { model.removeEmptySpace(space.id) } }
        }
    }
}

struct SpatialBoardView: View {
    @ObservedObject var model: AppModel
    let display: Display
    let unit: CGSize
    var editable = false
    var selectedID: String?
    var originID: String?
    var open: ((Space) -> Void)?
    var menu: ((Space) -> AnyView)?
    var vacancy: ((Int,Int) -> Void)?
    @State private var resize: (id:String,rect:SpaceRect)?
    @State private var spaceDrop: SpaceDropTarget?
    @State private var windowVacancy: GridPoint?
    private var spaces: [Space] { model.boardSpaces(display) }
    private var outline:BoardOutline { BoardOutline(spaces:spaces) }
    private var minRow:Int { outline.minRow }
    private var minColumn:Int { outline.minColumn }
    private var rail:CGFloat { editable ? MapPresentation.creationRail : 0 }
    private var canvasSize:CGSize { MapPresentation.boardSize(spaces:spaces,editable:editable) }
    var body: some View {
        ZStack(alignment:.topLeading) {
            if editable {
                ForEach(outline.vacancies,id: \.self) { point in
                    Button { vacancy?(point.row,point.column) } label: { Image(systemName:"plus").font(.caption).foregroundStyle(.secondary.opacity(0.55)).frame(width:vacancyFrame(point).width,height:vacancyFrame(point).height).contentShape(Rectangle()) }
                        .buttonStyle(.plain)
                        .overlay {
                            WindowDropSurface(model:model,hover:{ placement in
                                windowVacancy = placement == nil ? nil : point
                            },drop:{ window,_ in
                                model.createSpaceAt(row:point.row,column:point.column,moving:window,displayID:display.id)
                            })
                        }
                        .background(windowVacancy == point ? Color.accentColor.opacity(0.25) : .clear,in:RoundedRectangle(cornerRadius:5))
                        .offset(x:vacancyFrame(point).minX,y:vacancyFrame(point).minY)
                }
            }
            ForEach(spaces) { space in
                card(space)
                    .frame(width:CGFloat(space.rect.width)*unit.width-10,height:CGFloat(space.rect.height)*unit.height-10)
                    .offset(x:rail+CGFloat(space.column-minColumn)*unit.width,y:rail+CGFloat(space.row-minRow)*unit.height)
                    .id(space.id)
            }
            if editable {
                SpaceMoveSurface(model:model,headers:spaces.map { space in
                    (space.id,CGRect(x:frame(space.rect).minX+8,y:frame(space.rect).minY+8,width:frame(space.rect).width-50,height:38))
                },open:{ id in if let space = spaces.first(where: { $0.id == id }) { open?(space) } },move:handleSpaceMove)
            }
            if let target = spaceDrop, let edge = target.edge, let sourceID = model.draggedSpace,
               let plan = try? SpaceInsertion.plan(spaces:insertionMembers(sourceID),sourceID:sourceID,targetID:target.id,edge:edge,
                                                   closesSourceGap:closesSourceGap(sourceID)) {
                ForEach(insertionMembers(sourceID).filter { plan[$0.id] != $0.rect || $0.id == sourceID }) { space in
                    if let rect = plan[space.id] {
                        ZStack {
                            if space.id == sourceID {
                                VStack(alignment:.leading,spacing:5) {
                                    Text(model.displayName(space)).font(.caption.weight(.medium))
                                    MiniLayoutView(snapshot:model.layout(space),windows:model.windows(in:space))
                                }.padding(8).background(.regularMaterial,in:RoundedRectangle(cornerRadius:10))
                            }
                            RoundedRectangle(cornerRadius:10).stroke(Color.accentColor.opacity(0.7),style:StrokeStyle(lineWidth:2,dash:[5,4]))
                        }.frame(width:frame(rect).width,height:frame(rect).height)
                            .offset(x:frame(rect).minX,y:frame(rect).minY).allowsHitTesting(false)
                    }
                }
            }
            if let resize {
                let valid = fits(resize.rect,except:resize.id)
                RoundedRectangle(cornerRadius:10).fill(valid ? Color.accentColor.opacity(0.16) : Color.red.opacity(0.16))
                    .overlay(RoundedRectangle(cornerRadius:10).stroke(valid ? Color.accentColor : .red,lineWidth:2))
                    .overlay(Text(valid ? "Soltá para aplicar" : "No cabe acá").font(.caption).padding(6).background(.regularMaterial,in:Capsule()))
                    .frame(width:CGFloat(resize.rect.width)*unit.width-10,height:CGFloat(resize.rect.height)*unit.height-10)
                    .offset(x:rail+CGFloat(resize.rect.column-minColumn)*unit.width,y:rail+CGFloat(resize.rect.row-minRow)*unit.height).allowsHitTesting(false)
            }
        }.frame(width:canvasSize.width,height:canvasSize.height,alignment:.topLeading)
            .onChange(of:model.organizingDrag) { if !model.organizingDrag { resize = nil; spaceDrop = nil; windowVacancy = nil } }
    }
    private func handleSpaceMove(_ point:CGPoint?, ended:Bool) {
        guard let point, let sourceID = model.draggedSpace else { spaceDrop = nil; return }
        if let target = spaces.first(where: { $0.id != sourceID && frame($0.rect).insetBy(dx:-5,dy:-5).contains(point) }) {
            let bounds = frame(target.rect)
            let local = CGPoint(x:point.x-bounds.minX,y:point.y-bounds.minY)
            let destination = SpaceDropTarget(id:target.id,point:local,size:bounds.size)
            spaceDrop = destination
            if ended {
                if let edge = destination.edge { model.insertSpace(sourceID,beside:target.id,edge:edge) }
                else { model.moveSpace(sourceID,to:target.id) }
                spaceDrop = nil
            }
        } else {
            spaceDrop = nil
            if ended, let vacancy = outline.vacancies.first(where: { vacancyFrame($0).contains(point) }),
               let source = model.projectedSpaces.first(where: { $0.id == sourceID }) {
                var rect = source.rect; rect.row = vacancy.row; rect.column = vacancy.column
                model.setSpaceRect(sourceID,rect,displayID:display.id)
            }
        }
    }
    private func frame(_ rect:SpaceRect) -> CGRect {
        CGRect(x:rail+CGFloat(rect.column-minColumn)*unit.width,y:rail+CGFloat(rect.row-minRow)*unit.height,
               width:CGFloat(rect.width)*unit.width-10,height:CGFloat(rect.height)*unit.height-10)
    }
    private func insertionMembers(_ sourceID:String) -> [Space] {
        guard !spaces.contains(where: { $0.id == sourceID }), let source = model.projectedSpaces.first(where: { $0.id == sourceID }) else { return spaces }
        return spaces + [source]
    }
    private func closesSourceGap(_ sourceID:String) -> Bool {
        model.desktop?.displays.count == 1 || spaces.contains(where: { $0.id == sourceID })
    }
    private func fits(_ rect: SpaceRect,except id: String) -> Bool {
        (1...64).contains(rect.width) && (1...64).contains(rect.height) && !spaces.contains { $0.id != id && $0.rect.overlaps(rect) }
    }
    private func vacancyFrame(_ point:GridPoint) -> CGRect {
        let gridWidth = canvasSize.width-rail*2, gridHeight = canvasSize.height-rail*2
        var x = rail+CGFloat(point.column-minColumn)*unit.width
        var y = rail+CGFloat(point.row-minRow)*unit.height
        var width = unit.width-10, height = unit.height-10
        if point.column < outline.minColumn { x = 0; width = rail-3 }
        if point.column >= outline.maxColumn { x = rail+gridWidth+3; width = rail-3 }
        if point.row < outline.minRow { y = 0; height = rail-3 }
        if point.row >= outline.maxRow { y = rail+gridHeight+3; height = rail-3 }
        return CGRect(x:x,y:y,width:width,height:height)
    }
    private func directionBadge(_ space: Space) -> String {
        guard let desktop = model.desktop, let map = model.state.dynamicMap,
              let currentID = selectedID ?? model.currentSpace(on:display)?.id,
              let current = spaces.first(where: { $0.id == currentID }) else { return "" }
        let eligible = NavigationSelection.eligible(map:map,configuration:model.configuration,display:display,desktop:desktop)
        var anchor = model.gestureSelection?.selected[display.id] ?? map.anchors?[display.id]
        if anchor?.spaceID == current.id, let previous = anchor?.frame {
            anchor?.x += Double(current.column-previous.column)
            anchor?.y += Double(current.row-previous.row)
            anchor?.frame = current.rect
        }
        let symbols: [Direction:String] = [.left:"←",.right:"→",.up:"↑",.down:"↓"]
        return Direction.allCases.compactMap { direction -> String? in
            guard SpatialNavigation.candidates(from:current,anchor:anchor,direction:direction,spaces:spaces,eligible:eligible).first?.id == space.id else { return nil }
            let horizontal = direction == .left || direction == .right
            let overlaps = horizontal ? space.row < current.rect.bottom && space.rect.bottom > current.row : space.column < current.rect.right && space.rect.right > current.column
            return (symbols[direction] ?? "") + (overlaps ? "" : "↗")
        }.joined(separator:" ")
    }
    private func card(_ space: Space) -> some View {
        let current = selectedID ?? model.currentSpace(on:display)?.id
        let chosen = current == space.id
        return SpaceMiniCard(model:model,space:space,editable:editable,chosen:chosen,origin:originID == space.id,badge:directionBadge(space),
            open:{ open?(space) },menu:menu?(space),resize:{ rect,ended in
                if ended {
                    if rect != space.rect && fits(rect,except:space.id) { model.setSpaceRect(space.id,rect) }
                    resize = nil; model.organizingDrag = false
                } else {
                    resize = (space.id,rect); model.organizingDrag = true
                }
            },unit:unit,dropTarget:spaceDrop?.id == space.id ? spaceDrop : nil)
    }
}

private struct SpaceMiniCard: View {
    @ObservedObject var model: AppModel
    let space: Space
    let editable: Bool
    let chosen: Bool
    let origin: Bool
    let badge: String
    let open: () -> Void
    let menu: AnyView?
    let resize: (SpaceRect,Bool) -> Void
    let unit: CGSize
    let dropTarget: SpaceDropTarget?
    @State private var windowTargeted = false
    var body: some View {
        VStack(spacing:5) {
            HStack(spacing:4) {
                header
                if editable, let menu {
                    Menu { menu } label: { Image(systemName:"ellipsis").frame(width:26,height:22).contentShape(Rectangle()) }
                        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().help("Acciones del espacio")
                }
            }.frame(height:38)
            MiniLayoutView(snapshot:model.layout(space),windows:model.windows(in:space),model:editable && space.nativeWindow == nil ? model : nil,spaceID:space.id,onOpen:{ window in
                open(); if editable { model.focusWindow(window.identity) }
            })
        }.padding(8).background(chosen ? Color.accentColor.opacity(0.16) : Color(nsColor:.windowBackgroundColor).opacity(0.22),in:RoundedRectangle(cornerRadius:10))
            .overlay(RoundedRectangle(cornerRadius:10).stroke(chosen ? Color.accentColor : Color.secondary.opacity(origin ? 0.7 : 0.2),lineWidth:chosen ? 2 : 1))
            .contentShape(Rectangle()).onTapGesture(perform:open)
            .overlay {
                if editable && model.draggedSpace == nil && model.draggedWindow == nil {
                    ResizeBorder(rect:space.rect,unit:unit,onResize:resize)
                }
            }
            .overlay { SpaceDropHighlight(target:dropTarget).allowsHitTesting(false) }
            .opacity(model.draggedSpace == space.id ? 0.55 : 1)
            .overlay {
                if editable, space.nativeWindow == nil {
                    WindowDropSurface(model:model,spaceID:space.id,hover:{ placement in windowTargeted = placement != nil },drop:{ window,_ in model.moveWindow(window,to:space.id) })
                }
            }
            .overlay {
                if windowTargeted && model.draggedWindow != nil {
                    RoundedRectangle(cornerRadius:10).stroke(Color.accentColor,lineWidth:2).allowsHitTesting(false)
                }
            }
    }
    private var header: some View {
        HStack(spacing:4) {
            if editable {
                VStack(spacing:2) {
                    ForEach(0..<3) { _ in HStack(spacing:2) { Circle().frame(width:3,height:3); Circle().frame(width:3,height:3) } }
                }.foregroundStyle(.secondary).frame(width:14).accessibilityHidden(true)
            }
            if space.nativeWindow != nil { Image(systemName:"arrow.up.left.and.arrow.down.right").font(.caption2) }
            if origin { Image(systemName:"circle.inset.filled").font(.system(size:7)).help("Origen del gesto") }
            if !badge.isEmpty { Text(badge).font(.caption.weight(.bold)).foregroundStyle(.tint) }
            Text(model.displayName(space)).font(.system(size:13,weight:.medium)).lineLimit(2)
            Spacer(minLength:0)
        }.frame(maxWidth:.infinity,maxHeight:.infinity,alignment:.leading).contentShape(Rectangle())
            .onTapGesture(perform:open)
            .accessibilityLabel("Espacio completo: \(model.displayName(space))")
            .help(editable ? "Arrastrá este encabezado: bordes para insertar, centro para intercambiar" : model.displayName(space))
    }
}

struct SpatialHUDView: View {
    @ObservedObject var model:AppModel
    let display:Display
    private var selectedID:String? { model.gestureSelection?.selected[display.id]?.spaceID }
    var body:some View {
        VStack(spacing:8) {
            HStack {
                Text(display.builtin ? "MacBook" : display.name).font(.caption.weight(.medium))
                Spacer(); Text("Soltá para abrir").font(.caption).foregroundStyle(.secondary)
            }
            ScrollViewReader { proxy in
                ScrollView([.horizontal,.vertical]) {
                    SpatialBoardView(model:model,display:display,unit:MapPresentation.unit,selectedID:selectedID,originID:model.gestureSelection?.origin[display.id]?.spaceID)
                }.scrollIndicators(.hidden)
                    .onAppear { if let selectedID { proxy.scrollTo(selectedID,anchor:.center) } }
                    .onChange(of:selectedID) { if let selectedID { proxy.scrollTo(selectedID,anchor:.center) } }
            }
        }.padding(10).background(MapGlass())
    }
}

private struct LayoutEditorView: View {
    @ObservedObject var model:AppModel
    let space:Space
    let close:()->Void
    @State private var incoming:UInt32 = 0
    @State private var target:UInt32 = 0
    @State private var placement:GridCore.WindowPlacement = .right
    private var all:[WindowInfo] { (model.desktop?.windows ?? []).filter { !$0.nativeFullscreen && !$0.floating } }
    var body: some View {
        VStack(alignment:.leading,spacing:16) {
            HStack { Text(model.displayName(space)).font(.headline); Spacer(); Button("Listo",action:close) }
            MiniLayoutView(snapshot:model.layout(space),windows:model.windows(in:space),model:model,spaceID:space.id)
                .frame(width:500,height:270)
            Text("Arrastrá sobre el borde de una app para dividir ese grupo; al centro para apilar.").font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("Lado a lado") { model.arrange(space.id,layout:"tiles",orientation:"h") }
                Button("Vertical") { model.arrange(space.id,layout:"tiles",orientation:"v") }
                Button("Apiladas") { model.arrange(space.id,layout:"accordion",orientation:"h") }
            }
            Divider()
            Text("También podés elegir con clics").font(.caption.weight(.medium))
            Picker("Mover",selection:$incoming) { Text("Elegí una ventana").tag(UInt32(0)); ForEach(all) { Text("\($0.appName) · \($0.title)").tag($0.id) } }
            Picker("Respecto de",selection:$target) { Text("Elegí destino").tag(UInt32(0)); ForEach(model.windows(in:space).filter { !$0.floating && $0.id != incoming }) { Text("\($0.appName) · \($0.title)").tag($0.id) } }
            HStack {
                Picker("Posición",selection:$placement) { ForEach(GridCore.WindowPlacement.allCases,id: \.self) { Text($0.label).tag($0) } }.labelsHidden()
                Button("Aplicar") {
                    if let window = all.first(where: { $0.id == incoming }) { model.placeWindow(window.identity,in:space.id,group:[target],placement:placement) }
                }.disabled(incoming == 0 || target == 0 || incoming == target)
                Button("Extraer a nuevo espacio") { if let window = all.first(where: { $0.id == incoming }) { model.createSpace(near:space.id,moving:window.identity) } }.disabled(incoming == 0)
            }
        }.padding(24).frame(width:550)
    }
}

enum ResizeCursor {
    private static let descending = make(descending:true)
    private static let ascending = make(descending:false)
    static func diagonal(descending:Bool) -> NSCursor { descending ? self.descending : ascending }
    private static func make(descending:Bool) -> NSCursor {
        let image = NSImage(size:NSSize(width:24,height:24),flipped:false) { _ in
            let start = NSPoint(x:5,y:descending ? 19 : 5)
            let end = NSPoint(x:19,y:descending ? 5 : 19)
            let sign:CGFloat = descending ? -1 : 1
            let path = NSBezierPath()
            path.move(to:start); path.line(to:end)
            path.move(to:NSPoint(x:start.x+6,y:start.y));path.line(to:start);path.line(to:NSPoint(x:start.x,y:start.y+6*sign))
            path.move(to:NSPoint(x:end.x-6,y:end.y));path.line(to:end);path.line(to:NSPoint(x:end.x,y:end.y-6*sign))
            path.lineCapStyle = .round;path.lineJoinStyle = .round
            NSColor.white.setStroke();path.lineWidth = 4;path.stroke()
            NSColor.black.setStroke();path.lineWidth = 2;path.stroke()
            return true
        }
        return NSCursor(image:image,hotSpot:NSPoint(x:12,y:12))
    }
}
