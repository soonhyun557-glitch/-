# 제주시 강수량 Oracle 자동 전달 (Bifrost Testnet, 수업용)

## 이 패키지에 포함된 것
- `oracle.mjs`: 기존 배포된 EventEscrowOracle + FestivalOutcomeOracle에 연결하는 **외부 자동 보고 프로그램**
- `rainfall.mjs`: 강수량 합산/판정
- `.github/workflows/weather-oracle.yml`: 5분마다 반복 실행 + 수동 실행
- `contracts/`: 기존 스마트컨트랙트 코드 참고용(수정하지 않음)

## 판정 규칙
홈페이지에서 `createEvent()`로 생성된 **각 행사별 eventTime**을 온체인에서 읽습니다. 행사 시작 60초 전을 판단 기준 시각으로 계산합니다. 제주시 좌표(33.4996, 126.5312)의 Open-Meteo `minutely_15=precipitation` 15분 단위 자료 중 **기준시각 직전 마지막 완료된 15분 구간까지 16개 구간**(정확히 4시간)을 합산합니다. 0.1 mm 이상이면 `Cancelled(2)`, 미만이면 `Held(1)`을 Oracle에 전달합니다. 자료가 누락되면 판단하지 않습니다.

**중요:** 데이터는 Open-Meteo 예보/모델 기반이며 관측소의 확정 실측값이라고 주장하면 안 됩니다. 15분 경계로 맞추기 때문에 판단 구간 끝은 행사 시작 1분 전보다 최대 15분 앞설 수 있습니다. GitHub Actions의 5분 간격 예약 작업은 정확한 1분 전 실행을 보장하지 않습니다. 정확한 실행 시각 또는 검증된 실측 강수량이 필요하면 다른 스케줄러와 공식 관측 데이터 연동이 추가로 필요합니다.

`Cancelled` 결과가 전달되면 현재 `EventEscrowOracleAutoRefund.sol`에서는 **같은 트랜잭션 안에** 활성 참가자의 참가비와 기존 취소자의 보관 수수료를 자동 환불합니다(참가자 최대 20명, 토큰 이체 정상 작동 전제). 정상 개최 `Held`는 계약상 행사 시작 이후에만 보고 가능하며, 주최자 자금 정산은 기존 `withdrawFunds()`를 별도로 실행합니다. 주최자 정산까지 자동화하는 코드는 포함하지 않았습니다.

## 최초 설치 (사용자가 직접 해야 하는 부분)
1. GitHub에 **비공개 저장소**를 새로 만들고 이 압축파일의 내용 전체를 업로드합니다 (`.github` 숨김 폴더 포함).
2. 저장소 `Settings > Secrets and variables > Actions`에서 아래 **Repository secrets**를 설정합니다.
   - `ESCROW_ADDRESS`: **현재 사이트가 연결한** 자동 환불용 EventEscrowOracle 계약 전체 주소
   - `ORACLE_ADDRESS`: 해당 Escrow가 연결한 FestivalOutcomeOracle 계약 전체 주소
   - `ORACLE_REPORTER_PRIVATE_KEY`: 해당 Oracle 계약 `reporter()`로 등록된 **시연 전용 지갑** 개인키. 테스트용 BFC만 소액 보관; 개인키를 채팅/웹사이트/코드에 붙이지 마세요.
   - `BIFROST_RPC`: `https://public-01.testnet.bifrostnetwork.com/rpc`
3. `Actions` 탭에서 워크플로를 활성화하고 `Run workflow`를 한 번 실행합니다. `Events found: ...` 로그 확인.
4. 홈페이지에서 **같은 Escrow 계약 주소로** 행사를 새로 개설합니다. 작업은 모든 행사 ID를 조회합니다. 과거 행사, 이미 Oracle 처리한 행사는 건너뜁니다.
5. 테스트넷 Reporter 지갑에 거래 수수료용 BFC가 있어야 합니다.

## 중요한 위험 및 한계
- Netlify 사이트만 바꿔도 자동화되지 않습니다. GitHub Actions와 Secrets 설정이 **완료되어야** 자동으로 실행됩니다.
- 작업 실행 지연, RPC 장애, API 장애, 데이터 누락 또는 토큰 전송 실패 시 자동 환불이 실행되지 않을 수 있습니다. 실패 시 Actions 로그를 확인하고 워크플로를 재실행해야 합니다.
- 현재 소스에서는 수수료 정산 또는 계약 조건 수정이 자동으로 발생하지 않습니다. 블록체인에 올린 계약은 수정할 수 없으며 변경 시 새 계약 배포가 필요합니다.
- **실제 돈으로 사용하지 마세요.** 교육용 테스트넷 코드입니다.
