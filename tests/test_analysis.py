"""Analysis tests avoid model downloads; timing and repetition get real assertions."""
import json
import math
import importlib.util
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch
import wave

from videocreator.analysis import (
    AnalysisCancelled, AnalysisError, _check_cancel, _clean_words,
    _duration_from_probe, _fingerprint, _rate, _transcript_lines, _vfr_sample,
    align_lyrics, detect_sections, extract_frames, find_binary, normalize_text,
    analyze_audio, scan_clips,
)


def segment(words):
    return {'words': [{'word': word, 'start': start, 'end': end, 'probability': 0.95}
                      for word, start, end in words]}


def line(index, text, start=None, **extra):
    start = index * 4 if start is None else start
    return {'id': f'line_{index}', 'text': text, 'start': start, 'end': start + 3, **extra}


class MetadataTests(unittest.TestCase):
    def test_rational_frame_rate_is_preserved(self):
        fps = _rate('30000/1001')
        self.assertEqual((fps.numerator, fps.denominator), (30000, 1001))
        for invalid in ('0/0', 'N/A', '0/1', '-25', None, 'inf', '100000'):
            self.assertIsNone(_rate(invalid))

    def test_video_duration_uses_stream_time_base_before_container_audio_length(self):
        duration, source = _duration_from_probe(
            {'duration_ts': 300300, 'time_base': '1/30000', 'duration': '10.01'}, {'duration': '40'})
        self.assertAlmostEqual(duration, 10.01)
        self.assertEqual(source, 'stream_time_base')

    def test_missing_duration_does_not_invent_frame_count_division(self):
        with self.assertRaises(AnalysisError):
            _duration_from_probe({'nb_frames': '300', 'avg_frame_rate': '30/1'}, {})

    def test_fingerprint_survives_rename(self):
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / 'old.mov'
            path.write_bytes(b'visual-data' * 100)
            before = _fingerprint(path)
            renamed = path.rename(Path(folder) / 'new.mov')
            self.assertEqual(before, _fingerprint(renamed))
            renamed.write_bytes(b'new-data')
            self.assertNotEqual(before, _fingerprint(renamed))

    def test_sampled_vfr_is_based_on_frame_deltas(self):
        fixed = {'frames': [{'best_effort_timestamp_time': str(i / 25)} for i in range(20)]}
        variable = {'frames': [{'best_effort_timestamp_time': str(i / 25 + (0.08 if i >= 10 else 0))}
                               for i in range(20)]}
        with patch('videocreator.analysis.find_binary', return_value='/bundled/ffprobe'):
            with patch('videocreator.analysis._run', return_value=json.dumps(fixed).encode()):
                self.assertFalse(_vfr_sample(Path('/clip.mov')))
            with patch('videocreator.analysis._run', return_value=json.dumps(variable).encode()):
                self.assertTrue(_vfr_sample(Path('/clip.mov')))

    def test_binary_override_and_missing_error(self):
        with tempfile.TemporaryDirectory() as folder:
            binary = Path(folder) / 'ffprobe'
            binary.write_text('#!/bin/sh\n')
            binary.chmod(0o755)
            with patch.dict('os.environ', {'VC_BIN_DIR': folder}):
                self.assertEqual(find_binary('ffprobe'), str(binary.resolve()))
        with self.assertRaises(AnalysisError):
            find_binary('arbitrary-program')


class AlignmentTests(unittest.TestCase):
    def test_matching_lyrics_keep_real_word_boundaries_and_line_breaks(self):
        segments = [segment([('Hello,', 1, 1.5), ('world!', 1.6, 2.0), ('Take', 5, 5.4), ('me', 5.4, 5.8), ('home.', 5.8, 6.3)])]
        lines, quality = align_lyrics('Hello world\nTake me home', segments, 10)
        self.assertEqual(quality, 1)
        self.assertEqual([(row['start'], row['end']) for row in lines], [(1, 2), (5, 6.3)])
        self.assertEqual(lines[1]['text'], 'Take me home')
        self.assertTrue(all(not row['needs_review'] for row in lines))

    def test_missing_lyrics_interpolate_only_gap_and_require_review(self):
        segments = [segment([('Take', 1, 2), ('home', 5, 6)])]
        lines, quality = align_lyrics('Take\nme\nhome', segments, 10)
        self.assertAlmostEqual(quality, 2 / 3, places=3)
        self.assertEqual((lines[1]['start'], lines[1]['end']), (2, 5))
        self.assertTrue(lines[1]['needs_review'])
        self.assertTrue(lines[1]['timing_estimated'])
        self.assertFalse(lines[0]['needs_review'])

    def test_no_recognition_never_claims_precise_alignment(self):
        lines, quality = align_lyrics('[Verse]\nOne two\n\n[Chorus]\nThree four', [], 8)
        self.assertEqual(quality, 0)
        self.assertEqual([(row['start'], row['end']) for row in lines], [(0, 4), (4, 8)])
        self.assertTrue(all(row['needs_review'] for row in lines))
        self.assertNotEqual(lines[0]['group'], lines[1]['group'])
        self.assertEqual(lines[1]['section_label'], 'Chorus')

    def test_whisper_words_are_finite_monotonic_and_bounded(self):
        segments = [segment([('First', -2, 2), ('second', 1, 3), ('invalid', math.nan, 4), ('last', 5, 100)])]
        words = _clean_words(segments, 10)
        self.assertEqual([(w['start'], w['end']) for w in words], [(0, 2), (2, 3), (5, 10)])

    def test_segments_without_word_timestamps_are_marked_estimated(self):
        lines = _transcript_lines([{'start': 2, 'end': 6, 'text': 'This is a song.'}], 10)
        self.assertEqual((lines[0]['start'], lines[0]['end']), (2, 6))
        self.assertTrue(lines[0]['timing_estimated'])
        self.assertTrue(lines[0]['needs_review'])

    def test_normalization_handles_unicode_punctuation(self):
        self.assertEqual(normalize_text('  ÜBER—Straßen, HELLO! '), 'über strassen hello')


class SectionTests(unittest.TestCase):
    def test_explicit_refrains_reuse_first_section(self):
        lines = [line(0, 'Verse one', group=0), line(1, 'Stay with me', group=1, section_label='Refrain'),
                 line(2, 'Through the night', group=1, section_label='Refrain'),
                 line(3, 'Verse two', group=2), line(4, 'Stay with me!', group=3, section_label='Refrain'),
                 line(5, 'Through the night', group=3, section_label='Refrain')]
        sections = detect_sections(lines, 24)
        self.assertEqual(len(sections), 4)
        self.assertEqual(sections[3]['repeat_of'], sections[1]['id'])
        self.assertEqual(sections[0]['start'], 0)
        self.assertEqual(sections[-1]['end'], 24)
        for a, b in zip(sections, sections[1:]):
            self.assertEqual(a['end'], b['start'])

    def test_three_choruses_share_canonical_sequence(self):
        texts = ['First verse', 'Stay with me', 'Through the night', 'Second verse',
                 'Stay with me', 'Through the night', 'Third verse', 'Stay with me', 'Through the night']
        sections = detect_sections([line(i, text) for i, text in enumerate(texts)], 36)
        refrains = [s for s in sections if s['label'] == 'Refrain (Vorschlag)']
        self.assertEqual(len(refrains), 3)
        self.assertIsNone(refrains[0]['repeat_of'])
        self.assertEqual([s['repeat_of'] for s in refrains[1:]], [refrains[0]['id']] * 2)

    def test_single_repeated_word_is_not_chorus_evidence(self):
        sections = detect_sections([line(0, 'Yeah'), line(1, 'Hello'), line(2, 'Yeah')], 12)
        self.assertTrue(all(s['repeat_of'] is None for s in sections))

    def test_empty_text_creates_instrumental_section(self):
        sections = detect_sections([], 123.5)
        self.assertEqual(sections[0]['label'], 'Instrumental')
        self.assertEqual(sections[0]['end'], 123.5)


class CancellationTests(unittest.TestCase):
    def test_cancel_uses_dedicated_exception(self):
        with self.assertRaises(AnalysisCancelled):
            _check_cancel(lambda: True)

    def test_invalid_sampling_count_fails_before_cv2_import(self):
        for value in (0, -1, 31, True, 2.5):
            with self.assertRaises(AnalysisError):
                extract_frames({}, value)


class LocalIntegrationTests(unittest.TestCase):
    """Exercise actual bundled decoders and beat detection, never a remote model."""

    @classmethod
    def setUpClass(cls):
        try:
            cls.ffmpeg = find_binary('ffmpeg')
            find_binary('ffprobe')
        except AnalysisError as exc:
            raise unittest.SkipTest(str(exc))
        if not all(importlib.util.find_spec(name) for name in ('cv2', 'numpy', 'librosa')):
            raise unittest.SkipTest('Optionale Analysebibliotheken nicht installiert.')

    def test_real_video_scan_sample_and_rename_keep_catalog_identity(self):
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / 'Testclip ü.mov'
            subprocess.run([self.ffmpeg, '-nostdin', '-v', 'error', '-f', 'lavfi', '-i',
                            'testsrc2=size=320x180:rate=30000/1001:duration=2', '-c:v', 'mpeg4',
                            str(path)], check=True, capture_output=True, timeout=30)
            clips = scan_clips(folder)
            self.assertEqual(len(clips), 1)
            clip = clips[0]
            self.assertEqual((clip['width'], clip['height']), (320, 180))
            self.assertEqual((clip['fps_num'], clip['fps_den']), (30000, 1001))
            self.assertAlmostEqual(clip['duration'], 2.002, places=3)
            self.assertFalse(clip['is_vfr'])
            samples = extract_frames(clip, 3)
            self.assertEqual(len(samples), 3)
            self.assertTrue(all(sample['image'].startswith('/9j/') for sample in samples))
            self.assertTrue(samples[0]['time'] < samples[1]['time'] < samples[2]['time'])
            clip['description'] = 'Testmotiv'
            path.rename(Path(folder) / 'Sauber benannt.mov')
            rescanned = scan_clips(folder, clips)[0]
            self.assertEqual(rescanned['id'], clip['id'])
            self.assertEqual(rescanned['description'], 'Testmotiv')
            self.assertEqual(rescanned['original_name'], 'Testclip ü.mov')

    def test_real_120bpm_audio_needs_no_whisper_model(self):
        import numpy as np
        sr = 44100
        samples = np.zeros(sr * 8, dtype=np.float32)
        random = np.random.default_rng(42)
        click = random.normal(size=320) * np.exp(-np.linspace(0, 8, 320)) * 0.3
        for index in range(1, 16):
            first = int(sr * index * 0.5)
            samples[first:first + len(click)] += click
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / '120 bpm.wav'
            with wave.open(str(path), 'wb') as stream:
                stream.setnchannels(1)
                stream.setsampwidth(2)
                stream.setframerate(sr)
                stream.writeframes((samples * 32767).astype('<i2').tobytes())
            original_import = __import__
            def deny_whisper(name, *args, **kwargs):
                if name == 'mlx_whisper':
                    raise AssertionError('Beat-only-Analyse darf Whisper nicht importieren.')
                return original_import(name, *args, **kwargs)
            # Do not restore sys.modules wholesale: compiled soxr/nanobind types
            # cannot be unloaded and re-imported safely later in the same process.
            with patch('builtins.__import__', new=deny_whisper):
                result = analyze_audio(path, beats_only=True)
            self.assertAlmostEqual(result['duration'], 8, places=4)
            self.assertEqual(result['sample_rate'], 44100)
            self.assertEqual(result['analysis_sample_rate'], 16000)
            self.assertEqual(result['channels'], 1)
            self.assertFalse(result['transcribed'])
            self.assertEqual(result['lines'], [])
            self.assertTrue(12 <= len(result['beats']) <= 18)
            self.assertAlmostEqual(float(np.median(np.diff(result['beats']))), 0.5, delta=0.035)
            self.assertEqual(result['sections'][0]['label'], 'Instrumental')


@unittest.skipUnless(os.environ.get('VC_TEST_WHISPER') == '1', 'Echte GPU-/Modellprüfung ist explizit zuschaltbar.')
class WhisperIntegrationTests(unittest.TestCase):
    def test_local_german_speech_has_real_monotonic_word_timestamps(self):
        # Opt in only on a Mac with Metal access; the ordinary suite is offline.
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / 'sprachtest.aiff'
            subprocess.run(['/usr/bin/say', '-v', 'Anna', '-o', str(path),
                            'Hallo, dies ist ein kurzer Test. Wir schneiden ein Musikvideo im Takt der Musik.'],
                           check=True, capture_output=True, timeout=30)
            result = analyze_audio(path, whisper_model='mlx-community/whisper-tiny')
            self.assertTrue(result['transcribed'])
            self.assertEqual(result['language'], 'de')
            self.assertGreaterEqual(len(result['words']), 5)
            self.assertGreaterEqual(len(result['lines']), 1)
            self.assertTrue(all(0 <= word['start'] < word['end'] <= result['duration'] for word in result['words']))
            self.assertTrue(all(a['end'] <= b['start'] for a, b in zip(result['words'], result['words'][1:])))
            self.assertTrue(all(0 <= row['start'] < row['end'] <= result['duration'] for row in result['lines']))
            self.assertTrue(all(not row['timing_estimated'] for row in result['lines']))


if __name__ == '__main__':
    unittest.main()
