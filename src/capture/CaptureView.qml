// SPDX-FileCopyrightText: 2013 - 2022 Jolla Ltd.
// SPDX-FileCopyrightText: 2020 Open Mobile Platform LLC.
// SPDX-FileCopyrightText: 2024 - 2025 Jolla Mobile Ltd
//
// SPDX-License-Identifier: BSD-3-Clause

import QtQuick 2.4
import Nemo.Policy 1.0
import Nemo.Ngf 1.0
import Nemo.Notifications 1.0
import org.nemomobile.systemsettings 1.0
import Sailfish.Silica 1.0
import Sailfish.Policy 1.0
import com.jolla.camera 1.0
import org.sailfishos.PhotoApi 0.1

import "../settings"

FocusScope {
    id: captureView

    property bool active
    property int orientation
    property int effectiveIso: Settings.mode.iso
    property bool inButtonLayout: captureOverlay == null || captureOverlay.inButtonLayout
    property QtObject captureModel

    readonly property int viewfinderOrientation: {
        var rotation = 0
        switch (captureView.orientation) {
        case Orientation.Landscape: rotation = 90; break;
        case Orientation.PortraitInverted: rotation = 180; break;
        case Orientation.LandscapeInverted: rotation = 270; break;
        }

        return (720 - camera.info.orientation + rotation) % 360
    }
    property int captureOrientation
    property int pageRotation
    property bool orientationTransitionRunning

    property alias camera: camera
    property alias videoRecorder: videoRecorder
    property QtObject viewfinder

    readonly property bool recording: active && videoRecorder.recording

    property bool _unload

    property bool touchFocusSupported: camera.focusMode.value == FocusMode.AutoFocus
                                        || camera.focusMode.value == FocusMode.ContinuousAutoFocus

    // not bound to focusTimer.running, restarting timer shouldn't exit tap focus mode temporarily and lose focus state
    property bool tapFocusActive
    property bool _captureOnFocus
    property real _captureCountdown

    property bool reallyWideScreen: (Screen.height / Screen.width) >= 2.0
    // wide screen can move 4:3 viewfinder a little lower and avoid overlap with top&bottom buttons
    readonly property real viewfinderOffset: Math.min(0,
                                                      isPortrait ? (focusArea.width - height) / 2
                                                                 : (focusArea.width - width) / 2)
                                             + ((reallyWideScreen && (focusArea.width / focusArea.height <= 1.4))
                                                ? Theme.itemSizeLarge + Screen.topCutout.height
                                                : 0)

    readonly property bool isPortrait: orientation == Orientation.Portrait
                                       || orientation == Orientation.PortraitInverted
    readonly property bool effectiveActive: (active || recording) && (_startup || _applicationActive)
                                            && pageStack.depth < 2

    readonly property bool _canCapture: {
        return camera.configured
            && !videoMode || (captureOverlay != null && captureOverlay._recSecsRemaining > 0)
    }

    property bool _captureQueued
    property bool capturePending
    property bool captureBusy
    onCaptureBusyChanged: {
        if (!captureBusy && _captureQueued) {
            _captureQueued = false
            camera.captureImage()
        }
    }

    property bool handleVolumeKeys: camera.configured
                                    && keysResource.acquired
                                    && !videoMode
                                    && !captureView._captureOnFocus
    property bool captureOnVolumeRelease

    onHandleVolumeKeysChanged: {
        if (!handleVolumeKeys)
            captureOnVolumeRelease = false
    }

    property bool videoMode: Settings.global.captureMode === "video"
    property bool _startup: true

    readonly property bool _mirrorViewfinder: camera.info.facing === Camera.FrontFacing
    readonly property bool _horizontalMirror: _mirrorViewfinder && camera.info.orientation % 180 == 0
    readonly property bool _verticalMirror: _mirrorViewfinder && camera.info.orientation % 180 != 0

    readonly property bool _applicationActive: Qt.application.state == Qt.ApplicationActive

    property var captureOverlay: null

    signal recordingStopped(url url, string mimeType)
    signal loaded
    signal captured

    Item {
        id: captureSnapshot

        property alias sourceItem: captureSnapshotEffect.sourceItem

        visible: false
        anchors.verticalCenter: parent.verticalCenter
        width: parent.width*captureSnapshotEffect.scale
        height: parent.height*captureSnapshotEffect.scale

        ShaderEffectSource {
            id: captureSnapshotEffect

            hideSource: false
            live: false
            scale: 0.4
            anchors.centerIn: parent
            width: isPortrait ? captureView.width : captureView.height
            height: isPortrait ? captureView.height : captureView.width
            rotation: -captureView.pageRotation
        }
    }

    function setFocusPoint(point) {
        focusTimer.restart()
        camera.unlock(Camera.AllLocks)
        tapFocusActive = true
	var rects = [[point.x - 0.15, point.y - 0.15, point.x + 0.15, point.y + 0.15, 1]]
        camera.aeAreas.rects = rects
        camera.afAreas.rects = rects
        camera.awbAreas.rects = rects
        camera.trigger(Camera.AllLocks)
    }

    function _resetFocus() {
        focusTimer.running = false
        tapFocusActive = false
        camera.aeAreas.rects = []
        camera.afAreas.rects = []
        camera.awbAreas.rects = []
        camera.unlock(Camera.AllLocks)
    }

    function _triggerCapture() {
        // avoid duplicate capture if volume key and some other key trigger (e.g. shutter)
        captureOnVolumeRelease = false

        if (captureTimer.running) {
            captureTimer.reset()
        } else if (startRecordTimer.running) {
            startRecordTimer.running = false
        } else if (videoRecorder.recording) {
            videoRecorder.stop()
        } else if (_canCapture) {
            if (Settings.mode.timer != 0) {
                microphoneWarningNotification.publishIfNeeded()
                captureTimer.restart()
            } else if (!videoMode) {
                camera.captureImage()
            } else {
                microphoneWarningNotification.publishIfNeeded()
                camera.record()
            }
        }
    }

    function _openCamera(deviceId) {
        _resetFocus()
        camera.zoom.value = 1.0
        captureTimer.reset()
        Settings.global.deviceId = deviceId
        camera.cameraId = deviceId
        Settings.global.position = camera.info.facing
        if (camera.info.facing === Camera.BackFacing) {
            Settings.global.previousBackFacingDeviceId = deviceId
        }

        // Allow the camera to be closed when not needed
        camera.cameraId = Qt.binding(function () {
            return (effectiveActive || recording) ? deviceId : ""
        })
    }


    Notification {
        id: microphoneWarningNotification

        function publishIfNeeded() {
            if (videoMode && !AccessPolicy.microphoneEnabled) {
                microphoneWarningNotification.publish()
            }
        }

        urgency: Notification.Critical
        //: %1 is an operating system name without the OS suffix
        //% "Camera audio won't be recorded, microphone disabled by %1 Device Manager"
        body: qsTrId("jolla-camera-la-microphone_disallowed_by_policy")
            .arg(aboutSettings.baseOperatingSystemName)
    }

    onEffectiveIsoChanged: {
        if (effectiveIso == 0) {
            camera.exposureMode.value = ExposureMode.AutoExposure
        } else {
            camera.exposureMode.value = ExposureMode.PrioritizeSensitivity
            camera.sensitivity.value = Settings.mode.iso
        }
    }

    on_CanCaptureChanged: {
        if (!_canCapture) {
            startRecordTimer.running = false
        }
    }

    Component.onCompleted: {
        loadOverlay()
    }

    onEffectiveActiveChanged: {
        qrFilter.clearResult()

        if (!effectiveActive) {
            _resetFocus()
            captureTimer.reset()
        }
    }

    on_ApplicationActiveChanged: {
        if (_applicationActive) {
            _startup = false
        }
    }

    onVideoModeChanged: {
        imageCapture.enabled = !videoMode
        videoRecorder.enabled = videoMode
        camera.configure()
    }

    Timer {
        // prevent video recording continuing forever in the background
        running: recording && !effectiveActive
        interval: 60*1000
        onTriggered: videoRecorder.stop()
    }

    Timer {
        interval: 1000
        running: captureView._unload && !camera.active
        onTriggered: {
            captureView._unload = false
        }
    }

    /*
    Timer {
        id: reactivateTimer

        property int retryCounter
        readonly property bool abort: retryCounter >= 5

        interval: 1000
        running: camera.cameraStatus == Camera.LoadingStatus && !abort
        onTriggered: {
            // Try re-activate when stuck in loading status for 1sec.
            active = false
            active = true
            ++retryCounter
        }
    }
    */

    NonGraphicalFeedback {
        id: shutterEvent
        event: "camera_shutter"
    }

    NonGraphicalFeedback {
        id: recordStartEvent
        event: "video_record_start"
    }

    Timer {
        id: startRecordTimer

        interval: 200
        onTriggered: {
            captureOverlay.writeMetaData()
            videoRecorder.start()
            if (videoRecorder.recording) {
                videoRecorder.recordingChanged.connect(camera._finishRecording)
                extensions.disableNotifications(captureView, true)
            }
        }
    }

    SequentialAnimation {
        id: captureTimer

        property bool resetCameraOnStop

        function reset() {
            if (resetCameraOnStop) {
                _resetFocus()
                resetCameraOnStop = false
            }
            stop()
        }

        NumberAnimation {
            duration: Settings.mode.timer * 1000
            from: Settings.mode.timer
            to: 0
            easing.type: Easing.Linear
            target: captureView
            property: "_captureCountdown"
        }
        ScriptAction {
            script: {
                if (!videoMode) {
                    if (!tapFocusActive) {
                        camera.trigger()
                    }
                    camera.captureImage()
                } else {
                    camera.record()
                }

                if (captureTimer.resetCameraOnStop) {
                    _resetFocus()
                    captureTimer.resetCameraOnStop = false
                }
            }
        }
    }

    NonGraphicalFeedback {
        id: recordStopEvent
        event: "video_record_stop"
    }

    onRecordingStopped: {
        if (captureModel) {
            captureModel.appendCapture(url, mimeType)
        }
    }

    Camera {
        id: camera

        property bool hasCameraOnBothSides
        property var backFacingCameras

        Component.onCompleted: {
            var hasFrontFace = false
            var hasBackFace = false
            var backCameras = []

            for (var i = 0; i < CameraManager.availableCameras.length; i++) {
                var device = CameraManager.availableCameras[i]
                if (!hasFrontFace && device.facing === Camera.FrontFacing) {
                    hasFrontFace = true
                    Settings.global.frontFacingDeviceId = device.id
                } else if (device.facing === Camera.BackFacing) {
                    hasBackFace = true
                    backCameras.push(device)
                }
            }

            backFacingCameras = backCameras

            hasCameraOnBothSides = hasFrontFace && hasBackFace

            if (Settings.global.previousBackFacingDeviceId.length === 0 && backCameras.length > 0) {
                Settings.global.previousBackFacingDeviceId = backCameras[0].deviceId
            }

            viewfinder.stream.camera = camera
            _openCamera(Settings.deviceId)
        }

        onInitFailed: {
            console.log("Failed to initialize camera", cameraId)
        }

        onConfigFailed: {
            console.log("Failed to configure camera", cameraId)
        }

        onActiveChanged: {
            if (active && captureOverlay) {
                captureView.loaded()
            }
        }

	aeCompensation.value: Settings.global.exposureCompensation / 2.0

        focusMode.value: {
            // Could expect that locking focus on auto or continous behaves the same, but
            // continuous doesn't work as well.
            if (tapFocusActive) {
                return FocusMode.AutoFocus
            } else if (focusMode.supported.indexOf(FocusMode.ContinuousAutoFocus) >= 0) {
                return FocusMode.ContinuousAutoFocus
            } else if (focusMode.supported.length > 0) {
                return focusMode.supported[0]
            } else {
                return FocusMode.AutoFocus
            }
        }

        focusMode.onValueChanged: {
            unlockAutoFocus()
        }

        flashMode.value: Settings.mode.flash

        whiteBalanceMode.value: Settings.global.whiteBalance

        /*
        exposure {
            exposureMode: Settings.mode.exposureMode
            meteringMode: Settings.mode.meteringMode
        }
        */

        onCaptureDone: {
            if (successful) {
                var path = Settings.photoCapturePath('jpg')
                imageCapture.saveFrame(path)
                Settings.completePhoto(Qt.resolvedUrl(path))
            }
            camera.unlockAutoFocus()
            captureBusy = false
        }

        onShutter: {
            if (true /* camera.exposureMode.value != ExposureMode.HDR */) {
                shutterEvent.play()
                captureAnimation.start()
                // re-enable the shutter button
                capturePending = false
            } else {
                flashAnimation.start()
            }
        }

        // TODO: remove AutoFocus from the name, since this should also lock AE
        function lockAutoFocus() {
            captureOverlay.closeMenus()
            // timed capture locks when timer triggers
            if (!tapFocusActive && Settings.mode.timer == 0) {
                camera.trigger(Camera.AllLocks)
            }
        }

        function unlockAutoFocus() {
            camera.unlock(Camera.AllLocks)
        }

        function record() {
            videoRecorder.outputPath = Settings.videoCapturePath("mp4")
            startRecordTimer.running = true
            recordStartEvent.play()
        }

        function captureImage() {
            if (captureBusy) {
                _captureQueued = true
                return
            }

            capturePending = true
            captureBusy = true
            captureOverlay.writeMetaData()

            imageCapture.takePicture()

            if (focusTimer.running) {
                focusTimer.restart()
            }
        }

        function _finishRecording() {
            if (!videoRecorder.recording) {
                videoRecorder.recordingChanged.disconnect(_finishRecording)
                extensions.disableNotifications(captureView, false)
                var finalUrl = Settings.completeCapture(Qt.resolvedUrl(videoRecorder.outputPath))
                if (finalUrl != "") {
                    captureView.recordingStopped(finalUrl, videoRecorder.containerType)
                }
                recordStopEvent.play()
            }
        }

        /*
        // On some adaptations media booster makes camera initialization fail
        // and Camera must be reloaded, try to do that once when that happens.
        // Wait until the Camera item has completed and activation has been
        // requested before checking so its construction-time default
        // UnloadedState/UnloadedStatus is not treated as a reload failure.
        property bool reloadCheckEnabled
        property bool needsReload: reloadCheckEnabled
                                   && captureView.effectiveActive
                                   && (camera.errorCode === Camera.CameraError
                                       || (camera.cameraState === Camera.UnloadedState
                                           && camera.cameraStatus === Camera.UnloadedStatus))
        property bool initialized

        Component.onCompleted: reloadCheckEnabled = true

        onErrorCodeChanged: {
            if (errorCode == Camera.CameraError) {
                captureView._unload = true
            }
        }

        onNeedsReloadChanged: {
            if (needsReload) {
                captureView._unload = true
            }
        }

        deviceId: Settings.deviceId
        captureMode: Settings.global.captureMode == "image" ? Camera.CaptureStillImage
                                                            : Camera.CaptureVideo

        onCaptureModeChanged: {
            // Reset flash mode when changing to video mode
            if (initialized && captureMode === Camera.CaptureVideo) {
                Settings.mode.flash = Camera.FlashOff
            }
            captureView._resetFocus()
        }

        cameraState: {
            if (captureView.effectiveActive && !captureView._unload) {
                if (CameraConfigs.ready) {
                    return Camera.ActiveState
                } else {
                    return Camera.LoadedState
                }
            } else {
                return Camera.UnloadedState
            }
        }

        onCameraStateChanged: {
            if (cameraState == Camera.ActiveState && captureOverlay) {
                captureView.loaded()
            }
        }

        onCameraStatusChanged: {
            if (camera.cameraStatus === Camera.ActiveStatus) {
                reactivateTimer.retryCounter = 0
            } else {
                _captureQueued = false
                captureBusy = false
            }

            var backCameras = []
            if (cameraStatus === Camera.LoadedStatus && !initialized) {
                initialized = true
                var hasFrontFace = false
                var hasBackFace = false

                for (var i = 0; i < QtMultimedia.availableCameras.length; i++) {
                    var device = QtMultimedia.availableCameras[i]
                    if (!hasFrontFace && device.position === Camera.FrontFace) {
                        hasFrontFace = true
                        Settings.global.frontFacingDeviceId = device.deviceId
                    } else if (device.position === Camera.BackFace) {
                        hasBackFace = true
                        backCameras.push(device)
                    }
                }

                backFacingCameras = backCameras

                hasCameraOnBothSides = hasFrontFace && hasBackFace

                if (Settings.global.previousBackFacingDeviceId.length === 0 && backCameras.length > 0) {
                    if (backCameras.indexOf(QtMultimedia.defaultCamera.deviceId) >= 0) {
                        Settings.global.previousBackFacingDeviceId = QtMultimedia.defaultCamera.deviceId
                    } else {
                        Settings.global.previousBackFacingDeviceId = backCameras[0].deviceId
                    }
                }

                // Always disable flash torch at startup
                if (captureMode === Camera.CaptureVideo) {
                    Settings.mode.flash = Camera.FlashOff
                }
            }
        }

        imageCapture {
            resolution: _pickResolution(CameraConfigs.supportedImageResolutions, Settings.aspectRatio)

            onImageSaved: {
                // HDR case emits the exposed already on the first image, delay the feedback so user avoids
                // moving the device until it's safe again.
                if (camera.exposure.exposureMode == Camera.ExposureHDR) {
                    shutterEvent.play()
                    captureAnimation.start()
                }

                camera.unlockAutoFocus()
                captureBusy = false

                if (captureModel) {
                    captureModel.appendCapture(path, "image/jpeg")
                }

                Settings.completePhoto(Qt.resolvedUrl(path))
            }
            onImageExposed: {
                if (camera.exposure.exposureMode != Camera.ExposureHDR) {
                    shutterEvent.play()
                    captureAnimation.start()
                } else {
                    flashAnimation.start()
                }
            }
            onCaptureFailed: {
                camera.unlockAutoFocus()
                captureBusy = false
            }
        }
        videoRecorder {
            resolution: _pickResolution(CameraConfigs.supportedVideoResolutions, CameraConfigs.AspectRatio_16_9)

            audioChannels: 2
            audioSampleRate: Settings.global.audioSampleRate
            audioCodec: Settings.global.audioCodec
            videoCodec: Settings.global.videoCodec
            mediaContainer: Settings.global.mediaContainer

            videoEncodingMode: Settings.global.videoEncodingMode
            videoBitRate: Settings.global.videoBitRate
        }

        viewfinder {
            resolution: {
                var resolutions = CameraConfigs.supportedViewfinderResolutions
                if (resolutions.length > 0) {
                    return _pickViewfinderResolution(resolutions, Settings.aspectRatio)
                }
                return "-1x-1"
            }

            // Let gst-droid decide the best framerate
        }

        metaData {
            orientation: captureView.captureOrientation
            cameraModel: deviceInfo.prettyName
            cameraManufacturer: deviceInfo.manufacturer
        }

        focus.onFocusModeChanged: camera.unlock()

        onLockStatusChanged: {
            if (lockStatus != Camera.Searching && captureView._captureOnFocus) {
                captureView._captureOnFocus = false
                camera._completeCapture()
            }
        } */
    }

    function aspectRatioToFraction(aspectRatio) {
        var ratio = 4.0 / 3.0
        if (aspectRatio === CameraConfigs.AspectRatio_16_9) {
            ratio = 16.0 / 9.0
        } else if (aspectRatio !== CameraConfigs.AspectRatio_4_3) {
            console.warn("Unknown aspect ratio", aspectRatio)
        }
        return ratio
    }

    function _pickImageResolution(configs, aspectRatio) {
        var ratio = aspectRatioToFraction(aspectRatio)

        var bestWidth = 0

        for (var i = 0; i < configs.length; i++) {
            var cfg = configs[i]
            var minWidth = Math.max(cfg.width.min, cfg.height.min * ratio)
            var maxWidth = Math.min(cfg.width.max, cfg.height.max * ratio)
            if ((maxWidth - minWidth) > -0.5) {
                if (maxWidth > bestWidth) {
                    bestWidth = maxWidth
                }
            }
        }

        if (bestWidth == 0) {
            return {}
        }

        return {
            width: bestWidth,
            height: bestWidth / ratio
        }
    }

    function _pickViewfinderResolution(configs, aspectRatio) {
        var ratio = aspectRatioToFraction(aspectRatio)
        var idealWidth = Screen.width * ratio

        var bestDistanceLow = Infinity
        var bestDistanceHigh
        var bestWidth
        var bestCfg

        for (var i = 0; i < configs.length; i++) {
            var cfg = configs[i]
            var minWidth = Math.max(cfg.width.min, cfg.height.min * ratio)
            var maxWidth = Math.min(cfg.width.max, cfg.height.max * ratio)
            if ((maxWidth - minWidth) > -0.5) {
                var distanceLow = Math.max(idealWidth - maxWidth, 0)
                var distanceHigh = Math.max(minWidth - idealWidth, 0)
                var compare = (distanceLow - bestDistanceLow)
                        || (distanceHigh - bestDistanceHigh)
                        || (bestCfg.maxFps.max - cfg.maxFps.max)
                        || (cfg.minFps.min - bestCfg.minFps.min)
                if (compare < 0) {
                    bestDistanceLow = distanceLow
                    bestDistanceHigh = distanceHigh
                    bestWidth = Math.min(Math.max(minWidth, width), maxWidth)
                    bestCfg = cfg
                }
            }
        }

        if (!bestCfg) {
            return {}
        }

        return {
            width: bestWidth,
            height: bestWidth / ratio,
            minFps: bestCfg.minFps.min,
            maxFps: bestCfg.maxFps.max
        }
    }

    Binding {
        target: viewfinder.stream
        property: "configuration"
        value: _pickViewfinderResolution(viewfinder.stream.recommendedConfigurations, Settings.aspectRatio)
    }

    ImageCapture {
        id: imageCapture

        camera: captureView.camera
        enabled: !videoMode
        configuration: _pickImageResolution(recommendedConfigurations, Settings.aspectRatio)
    }

    VideoCapture {
        id: videoRecorder

        camera: captureView.camera
        enabled: videoMode
        //configuration: _pickImageResolution(recommendedConfigurations, Settings.aspectRatio)

        //audioChannels: 2
        //audioSampleRate: Settings.global.audioSampleRate
        audioType: Settings.global.audioCodec
        videoType: Settings.global.videoCodec
        containerType: Settings.global.mediaContainer

        //videoEncodingMode: Settings.global.videoEncodingMode
        videoBitrate: Settings.global.videoBitRate
    }

    Connections {
        target: Settings

        onDeviceIdChanged: {
            _openCamera(Settings.deviceId)
        }
    }

    DeviceInfo {
        id: deviceInfo
    }

    CameraExtensions {
        id: extensions
    }

    Rectangle {
        id: flashRectangle

        anchors.fill: parent
        color: "white"
        opacity: 0
    }

    SequentialAnimation {
        id: flashAnimation

        PropertyAction {
            target: flashRectangle
            property: "visible"
            value: true
        }
        OpacityAnimator {
            target: flashRectangle
            from: Theme.opacityHigh
            to: 0
            duration: 250
        }
        PropertyAction {
            target: flashRectangle
            property: "visible"
            value: false
        }
    }

    SequentialAnimation {
        id: captureAnimation

        PropertyAction {
            target: captureSnapshot
            property: "sourceItem"
            value: viewfinder
        }
        ScriptAction {
            script: captureSnapshotEffect.scheduleUpdate()
        }
        PropertyAction {
            target: captureSnapshot
            property: "x"
            value: 0
        }
        PropertyAction {
            target: captureSnapshot
            property: "visible"
            value: true
        }
        PropertyAction {
            target: viewfinder
            property: "opacity"
            value: 0
        }
        PauseAnimation {
            duration: 100
        }
        ParallelAnimation {
            XAnimator {
                target: captureSnapshot
                from: 0
                to: captureView.isPortrait ? -captureView.height : -captureView.width
                duration: 300
                easing.type: Easing.InQuad
            }
            OpacityAnimator {
                target: viewfinder
                to: 1
                duration: 300
            }
        }
        PropertyAction {
            target: captureSnapshot
            property: "visible"
            value: false
        }
        PropertyAction {
            target: captureSnapshot
            property: "sourceItem"
            value: null
        }
        ScriptAction {
            script: captureView.captured()
        }
    }

    property Component overlayComponent
    property var overlayIncubator

    function loadOverlay() {
        overlayComponent = Qt.createComponent("CaptureOverlay.qml", Component.Asynchronous, captureView)
        if (overlayComponent) {
            if (overlayComponent.status === Component.Ready) {
                incubateOverlay()
            } else if (overlayComponent.status === Component.Loading) {
                overlayComponent.statusChanged.connect(
                    function(status) {
                        if (overlayComponent) {
                            if (status == Component.Ready) {
                                incubateOverlay()
                            } else if (status == Component.Error) {
                                console.warn(overlayComponent.errorString())
                            }
                        }
                    })
            } else {
                console.log("Error loading capture overlay", overlayComponent.errorString())
            }
        }
    }

    function incubateOverlay() {
        overlayIncubator = overlayComponent.incubateObject(captureView,
                                                           { "captureView": captureView,
                                                             "camera": camera,
                                                             "focusArea": focusArea
                                                           }, Qt.Asynchronous)
        overlayIncubator.onStatusChanged = function(status) {
            if (status == Component.Ready) {
                captureOverlay = overlayIncubator.object
                captureOverlay.orientationTransitionRunning = Qt.binding(function () {
                    return captureView.orientationTransitionRunning
                })
                overlayFadeIn.start()
                overlayIncubator = null
                if (camera.active && captureOverlay) {
                    captureView.loaded()
                }
            } else if (status == Component.Error) {
                console.log("Failed to create capture overlay")
                overlayIncubator = null
            }
        }
    }

    FadeAnimator {
        id: overlayFadeIn

        target: captureOverlay
        to: 1.0
        duration: 100
    }

    Item {
        id: focusArea

        width: Screen.width
               * viewfinder.stream.width
               / viewfinder.stream.height
        height: Screen.width

        rotation: -captureView.viewfinderOrientation
        anchors {
            centerIn: parent
            verticalCenterOffset: isPortrait ? viewfinderOffset : 0
            horizontalCenterOffset: isPortrait ? 0 : viewfinderOffset
        }
        opacity: captureOverlay ? 1.0 - captureOverlay.settingsOpacity : 1.0

        Repeater {
            model: camera.afAreas.rects
            delegate: Item {
                x: focusArea.width * (captureView._horizontalMirror
                                      ? 1 - modelData[2]
                                      : modelData[0])
                y: focusArea.height * (captureView._verticalMirror
                                      ? 1 - modelData[3]
                                      : modelData[1])
                width: focusArea.width * (modelData[2] - modelData[0])
                height: focusArea.height * (modelData[3] - modelData[1])

		visible: tapFocusActive

                Rectangle {
                    width: Math.min(parent.width, parent.height)
                    height: width
                    anchors.centerIn: parent
                    radius: width / 2
                    border {
                        width: Math.round(Theme.pixelRatio * 2)
			color: true /* status == Camera.FocusAreaFocused */
                               ? (Theme.colorScheme == Theme.LightOnDark
                                  ? Theme.highlightColor
                                  : Theme.highlightFromColor(Theme.highlightColor, Theme.LightOnDark))
                               : "white"
                    }
                    color: "#00000000"
                }
            }
        }
    }

    Timer {
        id: focusTimer

        interval: 5000
        onTriggered: {
            if (!captureTimer.running) {
                captureView._resetFocus()
            } else {
                captureTimer.resetCameraOnStop = true
            }
        }
    }

    Keys.onVolumeDownPressed: {
        if (handleVolumeKeys && !event.isAutoRepeat) {
            camera.lockAutoFocus()
            captureOnVolumeRelease = true
        }
    }
    Keys.onVolumeUpPressed: {
        if (handleVolumeKeys && !event.isAutoRepeat) {
            camera.lockAutoFocus()
            captureOnVolumeRelease = true
        }
    }

    function supportedKey(key) {
        return key === Qt.Key_CameraFocus
                || key === Qt.Key_Camera
                || key === Qt.Key_VolumeDown
                || key === Qt.Key_VolumeUp
    }

    Keys.onPressed: {
        if (supportedKey(event.key)) {
            event.accepted = true
        }

        if (event.isAutoRepeat) {
            return
        }

        if (event.key == Qt.Key_CameraFocus) {
            camera.lockAutoFocus()
        } else if (event.key == Qt.Key_Camera) {
            captureView._triggerCapture() // key having half-pressed state too so can capture already here
        }
    }

    Keys.onReleased: {
        if (supportedKey(event.key)) {
            event.accepted = true
        }

        if (event.isAutoRepeat) {
            return
        }

        if (event.key == Qt.Key_CameraFocus) {
            // note: forces capture if it was still pending. debatable if that should be allowed to finish.
            camera.unlockAutoFocus()
        } else if ((event.key == Qt.Key_VolumeDown || event.key == Qt.Key_VolumeUp)
                   && captureOnVolumeRelease && handleVolumeKeys) {
            captureView._triggerCapture()
        }
    }

    Permissions {
        enabled: captureView.activeFocus
                    && !videoMode
                    && camera.active
        autoRelease: true
        applicationClass: "camera"

        Resource {
            id: keysResource

            type: Resource.ScaleButton
            optional: true
        }
    }

    Permissions {
        enabled: Qt.application.state == Qt.ApplicationActive
        autoRelease: true
        applicationClass: "camera"

        Resource {
            type: Resource.SnapButton
            optional: true
        }
    }

    AboutSettings {
        id: aboutSettings
    }
}
