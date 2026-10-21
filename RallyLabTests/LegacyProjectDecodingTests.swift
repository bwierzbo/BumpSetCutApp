//
//  LegacyProjectDecodingTests.swift
//  RallyLabTests
//
//  Every shape of project.json and sessions/*.json that exists on disk must
//  keep loading after the provenance fields (D-009) were added, and the new
//  fields must round-trip without touching anything else.
//

import XCTest
@testable import RallyLab

final class LegacyProjectDecodingTests: XCTestCase {

    private var decoder: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }

    private var encoder: JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.sortedKeys]
        return e
    }

    /// A Test1-era clip card (2026-09): no `split`, no `pulledFrom`, no provenance.
    private let test1Project = """
    {"name":"Test1","createdAt":"2026-09-28T02:46:36Z","framesPerRally":40,"clips":[
      {"id":"bch_onl_sun_land_onl_01","number":1,"environment":"Beach","camera":"Online","lighting":"Sun","orientation":"Landscape","ball":"Beach","notes":"",
       "videos":[{"kind":"link","origin":"https://www.youtube.com/watch?v=abc123DEF45","start":300,"length":300,"license":"permission: channel, email, 2026-10-06","title":"Beach game","uploader":"Some Channel","clipFile":"/Users/x/footage/raw/online/beach/bch_onl_sun_land_onl_01.mp4","fetchedAt":"2026-09-29T01:00:00Z","videoId":"bch_onl_sun_land_onl_01","fingerprint":"youtube:abc123DEF45"}]}
    ]}
    """

    /// The oldest shape: one `source` per card instead of `videos`.
    private let singleSourceProject = """
    {"name":"Old","createdAt":"2026-08-01T00:00:00Z","framesPerRally":40,"clips":[
      {"id":"ind_ele_dim_land_self_01","number":1,"environment":"Indoor","camera":"Elevated","lighting":"Dim","orientation":"Landscape","ball":"Indoor","notes":"n",
       "source":{"kind":"file","origin":"/Users/x/old.mov","start":0,"length":240,"license":"own","title":"Old","uploader":"","clipFile":"/Users/x/footage/raw/self/indoor/ind_ele_dim_land_self_01.mov","fetchedAt":"2026-08-01T00:00:00Z"}}
    ]}
    """

    /// A Scratch-era card with the fields that came later, plus provenance.
    private let scratchProjectWithProvenance = """
    {"name":"Scratch","createdAt":"2026-10-06T22:00:41Z","framesPerRally":40,"clips":[
      {"id":"grs_onl_sun_land_onl_01","number":7,"environment":"Grass","camera":"Online","lighting":"Sun","orientation":"Landscape","ball":"Outdoor","notes":"","split":"val","pulledFrom":null,
       "videos":[
         {"kind":"link","origin":"https://youtu.be/zzz","start":0,"length":300,"license":"permission","title":"A","uploader":"Grace","clipFile":"/f/a.mp4","fetchedAt":"2026-10-06T22:10:00Z","videoId":"grs_onl_sun_land_onl_01","fingerprint":"youtube:zzz","sourceId":"src-zzz","sessionId":"sess-1","venueId":"venue-park-1"},
         {"kind":"link","origin":"https://youtu.be/yyy","start":0,"length":300,"license":"permission","title":"B","uploader":"Grace","clipFile":"/f/b.mp4","fetchedAt":"2026-10-06T22:11:00Z","videoId":"grs_onl_sun_land_onl_01_v2","fingerprint":"youtube:yyy"}
       ]}
    ]}
    """

    func testTest1ShapeDecodesWithNilProvenance() throws {
        let project = try decoder.decode(Project.self, from: Data(test1Project.utf8))
        XCTAssertEqual(project.clips.count, 1)
        let clip = project.clips[0]
        XCTAssertNil(clip.split)
        XCTAssertNil(clip.pulledFrom)
        XCTAssertEqual(clip.videos.count, 1)
        let video = clip.videos[0]
        XCTAssertEqual(video.fingerprint, "youtube:abc123DEF45")
        XCTAssertNil(video.sourceId)
        XCTAssertNil(video.sessionId)
        XCTAssertNil(video.venueId)
        XCTAssertEqual(clip.videoId(of: video), "bch_onl_sun_land_onl_01")
    }

    func testTest1ShapeReencodesWithoutProvenanceKeys() throws {
        let project = try decoder.decode(Project.self, from: Data(test1Project.utf8))
        let text = String(decoding: try encoder.encode(project), as: UTF8.self)
        XCTAssertFalse(text.contains("sourceId"), "nil provenance must not be written")
        XCTAssertFalse(text.contains("sessionId"))
        XCTAssertFalse(text.contains("venueId"))
        let again = try decoder.decode(Project.self, from: Data(text.utf8))
        XCTAssertEqual(again, project)
    }

    func testSingleSourceShapeBecomesOneVideo() throws {
        let project = try decoder.decode(Project.self, from: Data(singleSourceProject.utf8))
        let clip = project.clips[0]
        XCTAssertEqual(clip.videos.count, 1)
        XCTAssertEqual(clip.videos[0].kind, .file)
        XCTAssertNil(clip.videos[0].videoId)
        XCTAssertEqual(clip.videoId(of: clip.videos[0]), clip.id, "a video without its own ID is named after the card")
        XCTAssertNil(clip.videos[0].sourceId)
    }

    func testProvenanceFieldsRoundTrip() throws {
        let project = try decoder.decode(Project.self, from: Data(scratchProjectWithProvenance.utf8))
        let clip = project.clips[0]
        XCTAssertEqual(clip.split, "val")
        XCTAssertEqual(clip.videos[0].sourceId, "src-zzz")
        XCTAssertEqual(clip.videos[0].sessionId, "sess-1")
        XCTAssertEqual(clip.videos[0].venueId, "venue-park-1")
        XCTAssertNil(clip.videos[1].sourceId, "a sibling without provenance stays unknown")
        let again = try decoder.decode(Project.self, from: try encoder.encode(project))
        XCTAssertEqual(again, project)
        XCTAssertEqual(again.clips[0].videos[0].venueId, "venue-park-1")
    }

    // MARK: - Sessions

    private let minimalSession = """
    {"name":"bch_extra_self_24","sourcePath":"/Users/x/footage/raw/self/beach/bch_extra_self_24.mov","split":"val","addedAt":"2026-10-14T01:02:03Z","frames":[]}
    """

    private let fullSession = """
    {"name":"ind_ele_bright_land_self_01","sourcePath":"/Users/x/v.mp4","split":"train","addedAt":"2026-10-07T00:00:00Z",
     "frames":[{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","file":"images/train/ind_ele_bright_land_self_01_00012_500.jpg","time":12.5,"source":"rally:0","boxes":[{"x":0.5,"y":0.5,"w":0.02,"h":0.03,"confidence":0.9}],"keep":true,"reviewed":true}],
     "ralliesMarked":true,"notRallies":[12.0],"fittedTracks":[],"syncedTrackIds":[],"tracks":[],"someFutureKey":{"a":1}}
    """

    func testMinimalSessionDecodes() throws {
        let session = try decoder.decode(VideoSession.self, from: Data(minimalSession.utf8))
        XCTAssertEqual(session.split, "val")
        XCTAssertNil(session.ralliesMarked)
        XCTAssertNil(session.tracks)
        XCTAssertEqual(session.frames.count, 0)
    }

    func testFullSessionDecodesAndIgnoresUnknownKeys() throws {
        let session = try decoder.decode(VideoSession.self, from: Data(fullSession.utf8))
        XCTAssertEqual(session.ralliesMarked, true)
        XCTAssertEqual(session.frames.count, 1)
        XCTAssertEqual(session.reviewedCount, 1)
        XCTAssertEqual(session.notRallies, [12.0])
        let again = try decoder.decode(VideoSession.self, from: try encoder.encode(session))
        XCTAssertEqual(again, session)
    }

    // MARK: - validation.json

    func testValidationSetWithoutFinalTestDecodes() throws {
        let set = try JSONDecoder().decode(PipelineTuner.ValidationSet.self, from: Data(#"{"tune":["a","b"],"holdout":["c"]}"#.utf8))
        XCTAssertEqual(set.tune, ["a", "b"])
        XCTAssertEqual(set.holdout, ["c"])
        XCTAssertEqual(set.finalTest, [])
    }

    func testValidationSetWithFinalTestRoundTrips() throws {
        let set = PipelineTuner.ValidationSet(tune: ["a"], holdout: ["b"], finalTest: ["z"])
        let again = try JSONDecoder().decode(PipelineTuner.ValidationSet.self, from: try JSONEncoder().encode(set))
        XCTAssertEqual(again.finalTest, ["z"])
        XCTAssertEqual(again.tune, ["a"])
    }
}
