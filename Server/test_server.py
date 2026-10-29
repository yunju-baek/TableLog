import io
import sys
import json
import tempfile
import time
import unittest
import wave
from pathlib import Path
from fastapi.testclient import TestClient
from server import Devices, create_app, MODEL, TEXT_MODEL, MAX_BODY


class ServerTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.devices = Devices(self.root / "state")
        worker = self.root / "worker.py"
        worker.write_text('import sys,json,pathlib\npathlib.Path(sys.argv[4]).write_text(json.dumps({"text":"테스트","segments":[{"start":0,"end":1,"text":"테스트"}]}))\n')
        text_worker = self.root / "text_worker.py"
        text_worker.write_text('import sys,json,pathlib\npathlib.Path(sys.argv[4]).write_text(json.dumps({"choices":[{"message":{"content":"합성 회의 요약"}}]}))\n')
        self.client = TestClient(create_app(self.devices, worker, text_worker, sys.executable))

    def tearDown(self):
        self.client.close(); self.temp.cleanup()

    def pair(self):
        code = self.devices.issue("test tablet")
        result = self.client.post("/v1/devices/connect", json={"code":code})
        self.assertEqual(result.status_code,200)
        return {"Authorization":"Bearer " + result.json()["access_token"]}, code, result.json()

    def test_authentication_replay_revocation_and_no_network_admin(self):
        self.assertEqual(self.client.get("/health").status_code,200)
        self.assertEqual(self.client.get("/v1/models").status_code,401)
        header, code, device = self.pair()
        self.assertEqual(self.client.post("/v1/devices/connect",json={"code":code}).status_code,401)
        self.assertEqual(self.client.get("/v1/models",headers=header).status_code,200)
        self.assertEqual(self.client.post("/v1/devices/issue-code",headers=header).status_code,404)
        self.assertEqual(self.client.get("/docs",headers=header).status_code,404)
        self.assertEqual(self.client.post("/v1/devices/revoke",headers=header).status_code,200)
        self.assertEqual(self.client.get("/v1/models",headers=header).status_code,403)
        self.assertNotIn(device["access_token"], self.devices.path.read_bytes().decode(errors="ignore"))

    def test_expired_codes_and_tokens(self):
        code = self.devices.issue("expired")
        with self.devices.connect() as db: db.execute("UPDATE codes SET expires=0")
        self.assertEqual(self.client.post("/v1/devices/connect",json={"code":code}).status_code,401)
        header, _, _ = self.pair()
        with self.devices.connect() as db: db.execute("UPDATE devices SET expires=0")
        self.assertEqual(self.client.get("/v1/models",headers=header).status_code,401)

    def test_independent_device_revocation(self):
        one, _, _ = self.pair(); two, _, _ = self.pair()
        self.client.post("/v1/devices/revoke",headers=one)
        self.assertEqual(self.client.get("/v1/models",headers=two).status_code,200)

    def test_input_limits_and_transcription_contract(self):
        header, _, _ = self.pair()
        self.assertEqual(self.client.post("/v1/audio/transcriptions",headers={**header,"Content-Length":str(MAX_BODY+1)},content=b"").status_code,413)
        fields = {"model":MODEL,"language":"ko","response_format":"verbose_json"}
        self.assertEqual(self.client.post("/v1/audio/transcriptions",headers=header,data=fields,files={"file":("a.wav",b"not wave")}).status_code,422)
        buffer = io.BytesIO()
        with wave.open(buffer,"wb") as wav:
            wav.setparams((1,2,16000,0,"NONE","not compressed")); wav.writeframes(bytes(32000))
        result = self.client.post("/v1/audio/transcriptions",headers=header,data=fields,files={"file":("../../ignored.wav",buffer.getvalue())})
        self.assertEqual(result.status_code,200,result.text)
        self.assertEqual(result.json()["text"],"테스트")
        self.assertFalse(self.client.get("/health").json()["busy"])

    def test_text_authentication_models_and_bounded_contract(self):
        payload = {"model":TEXT_MODEL,"messages":[{"role":"user","content":"합성 회의 요약"}],"stream":False}
        self.assertEqual(self.client.post("/v1/chat/completions",json=payload).status_code,401)
        header, _, paired = self.pair()
        self.assertEqual(paired["text_model"],TEXT_MODEL)
        self.assertIn(TEXT_MODEL,[m["id"] for m in self.client.get("/v1/models",headers=header).json()["data"]])
        response = self.client.post("/v1/chat/completions",headers=header,json=payload)
        self.assertEqual(response.status_code,200,response.text)
        self.assertEqual(response.json()["choices"][0]["message"]["content"],"합성 회의 요약")
        self.assertEqual(self.client.post("/v1/chat/completions",headers=header,json={**payload,"tools":[{"name":"shell"}]}).status_code,422)
        self.assertEqual(self.client.post("/v1/chat/completions",headers=header,json={**payload,"model":"../../another-model"}).status_code,422)
        self.assertEqual(self.client.post("/v1/chat/completions",headers=header,json={**payload,"messages":[{"role":"user","content":"x"*45001}]}).status_code,422)
        self.assertEqual(self.client.post("/v1/chat/completions",headers=header,json={**payload,"max_tokens":999999}).status_code,422)
        self.assertFalse(self.client.get("/health").json()["text_busy"])

    def test_code_rate_limit(self):
        for _ in range(20): self.client.post("/v1/devices/connect",json={"code":"AAAAAAAAAAAA"})
        self.assertEqual(self.client.post("/v1/devices/connect",json={"code":"AAAAAAAAAAAA"}).status_code,429)


if __name__ == "__main__": unittest.main()
