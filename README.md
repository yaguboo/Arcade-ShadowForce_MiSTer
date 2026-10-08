# Shadow Force — MiSTer FPGA 코어

> [!IMPORTANT]
> **취미로 만든 프로젝트입니다.**
> 개인이 순전히 취미로 만든 코어입니다. 버그 제보는 반갑게 받지만, **대응할 수도 있고 못 할 수도 있습니다.**
> 업데이트나 지원을 약속하지 않습니다.
>
> **이 코드로 이어서 개발하실 때는 꼭 출처를 남겨 주세요.**
> 이 저장소를 바탕으로 수정하거나 다른 코어를 만드실 때 출처(이 저장소 링크)를 밝혀 주시면 정말 감사하겠습니다.
> 라이선스(GPL-3.0)에 따라 원래의 저작권 표시와 이 프로젝트가 감사를 전한 분들의 출처도 함께 유지해 주세요.

1993년 Technos Japan 의 아케이드 기판 **TA-0032-P1-24** 를 FPGA 로 다시 만든
MiSTer 코어입니다. 이 기판에서 돌아가는 벨트스크롤 액션 게임 *Shadow Force*
(일본판 *Shadow Force - 변신닌자*)를 실행합니다.

원래 기판은 다음과 같이 구성되어 있습니다.

| 블록 | 부품 | 클럭 |
|---|---|---|
| 메인 CPU | Motorola 68000 | 14 MHz (28 MHz / 2) |
| 사운드 CPU | Zilog Z80 | 3.579545 MHz |
| FM 음원 | Yamaha YM2151 (+ YM3012 DAC) | 3.579545 MHz |
| PCM 음원 | OKI M6295 | 1.6869 MHz (13.4952 MHz / 8), pin 7 HIGH |
| 비디오 | TJ-002 / TJ-004 / TJ-005 커스텀 + Actel A1010A | 픽셀 클럭 7 MHz (28 MHz / 4) |

화면은 320×240, 57.4446 Hz 이고, 16×16 타일 배경 두 장(bg0 투명 / bg1 불투명),
8×8 텍스트 레이어(fg), 16×16 5bpp 스프라이트, 16,384색 xBGR555 팔레트로
이루어집니다. MAME 드라이버가 모든 클럭에 "verified on PCB" 를 달아 두었고
세 크리스털의 실측 주파수까지 기록해 두어서, 처음부터 타이밍 근거가 아주
튼튼한 기판이었습니다. 이 코어의 모든 비율(픽셀 클럭, 프레임 주기, YM 클럭,
OKI 샘플레이트, 프레임당 OKI 샘플 수)은 MAME 와 0.0000 % 차이로 일치합니다.

DE10-Nano(MiSTer)에서 그림·스프라이트·타일맵 세 장·팔레트·화면 반전·사운드가
모두 동작하며, 사람이 실제로 게임을 플레이했습니다.

## 지원 게임

| MAME 세트 | 공식 명칭 | 상태 |
|---|---|---|
| `shadfrce` | Shadow Force (World, Version 3) | **실기에서 플레이 확인.** 그림·사운드·입력 정상, 펀치+킥 동시입력 빙의까지 확인 |
| `shadfrceu` | Shadow Force (US, Version 2) | ROM CRC 검증·`.mra` 생성 완료(6버튼, 미국판 전용 DSW2 기본값 `0xFB`). **실기 플레이 기록 없음** |
| `shadfrcej` | Shadow Force - Henshin Ninja (Japan, Version 2) | **실기에서 플레이 확인.** 그림·사운드·입력(코인·스타트·게임 진행) 정상 |

세 세트 모두 하나의 코어(`ShadowForce.rbf`)를 사용하며, 세트별 차이(ROM,
리셋 벡터, DIP 기본값, 버튼 구성)는 `.mra` 가 정합니다. 배포용 `.mra` 는
`SD/_Arcade/_Kaze's Cores/` 에 있습니다.

## 설치 — ROM 만 넣으면 됩니다

이 배포본의 `SD/` 폴더는 MiSTer SD 카드의 루트(`/media/fat/`)와 같은 구조입니다.
**`SD/` 안의 내용을 SD 카드 루트에 그대로 복사**하면 됩니다.

```
SD/_Arcade/cores/ShadowForce.rbf                 코어 (빌드된 비트스트림)
SD/_Arcade/_Kaze's Cores/<게임 이름>.mra    게임 목록 (공식 명칭)
SD/games/mame/필요한_ROM.txt               넣어야 할 ROM zip 목록
```

1. `SD/` 의 내용을 SD 카드 루트에 복사합니다. 기존 파일은 덮어써도 됩니다.
2. 직접 마련한 MAME ROM 세트 zip 을 SD 카드의 `/games/mame/` 에 넣습니다.
   어떤 zip 이 필요한지는 `필요한_ROM.txt` 에 게임별로 적혀 있습니다.
   zip 은 MAME 세트 이름 그대로 두고, 압축을 풀지 않습니다.
3. MiSTer 메뉴에서 **Arcade → `_Kaze's Cores`** 로 들어가 게임을 고릅니다.

- `.rbf` 를 직접 실행하지 말고 `.mra` 로 실행하세요. ROM 로드와 DIP·OSD 기본값이
  `.mra` 에 들어 있습니다.
- 폴더 이름이 `_` 로 시작해야 MiSTer 메뉴에 보입니다. 이름을 바꾸지 마세요.


## 빌드 방법

필요한 것: **Intel Quartus Prime Lite Edition 17.0** (MiSTer 코어 표준 버전). 다른 버전에서도
합성은 될 수 있지만 검증한 버전은 17.0 입니다.

```sh
cd projects/technos/shadow_force/targets/mister
quartus_sh --flow compile ShadowForce
```

결과물은 `projects/technos/shadow_force/targets/mister/output_files/ShadowForce.rbf` 입니다. Quartus GUI 로
`ShadowForce.qpf` 를 열고 Compile 을 눌러도 같습니다.

- 디렉터리 구조를 그대로 유지해야 합니다. 프로젝트 파일이 `../../../../../third_party`,
  `../../../../../platforms/mister/sys` 를 상대 경로로 찾습니다.
- `build_id.v` 는 빌드 시작 때 `platforms/mister/sys/build_id.tcl` 이 자동으로 만듭니다.
- Quartus 17.0 의 fitter 가 드물게 내부 오류로 죽으면서도 정상 종료 코드를 남기는 경우가 있습니다.
  `.rbf` 의 생성 시각과 로그 끝부분을 확인하고, 그런 경우 한 번 더 빌드하면 됩니다.

직접 빌드한 `.rbf` 는 `SD/_Arcade/cores/` 의 같은 이름 파일과 바꿔 넣으면 됩니다.

## 디렉터리 구성

원래 저장소의 상대 경로를 그대로 유지했습니다. 빌드에 실제로 쓰이는 파일만 들어 있습니다.

```
LICENSE                              GPL-3.0 전문
README.md                            이 문서
SD/                                  SD 카드 루트에 복사할 설치 파일 (RBF, MRA, ROM 목록)
projects/technos/shadow_force/
  rtl/                               기판 하드웨어 RTL (68000·Z80 버스, 비디오·사운드, 메모리 RTL)
  integration/                       ROM 다운로드 경로 (플랫폼 중립 어댑터)
  targets/mister/                    MiSTer 최상위 (.qpf .qsf .sdc .sv files.qip, PLL)
third_party/                         외부 IP (아래 "감사의 말과 사용한 코드" 참조)
platforms/mister/sys/                MiSTer framework (Template_MiSTer)
```

소스 주석에는 개발 중에 쓴 내부 문서 번호와 측정 기록이 그대로 남아 있습니다. 해당 개발
문서와 측정·분석 도구는 이 배포본에 포함하지 않았습니다. 빌드에는 영향이 없습니다.

## 작업 내역

### 2026-10-08 — v0.9.1

- **타이틀 로고의 FORCE.** FORCE 는 bg0 맵 아래쪽 절반에만 있고, 게임이 라인마다 오는 래스터 인터럽트에서 bg0 세로 스크롤을 바꿔 화면에 올립니다. 이전 코어는 그 인터럽트를 프레임당 한 번만 내서 FORCE 가 간헐적으로만 보였습니다. MAME·FBNeo 와 같게 매 라인으로 바꿨고, 실기 로고가 MAME 와 픽셀 위치까지 같습니다.
- **무거운 장면의 프레임 드랍·깜박임, 코요테 스테이지 폭포 하단 글리치.** 68000 ROM 캐시(1K 워드)가 텐구 장면에서 프레임당 약 7,100번 미스를 내 CPU 가 원래 속도의 약 70% 로 돌았습니다. 16K 워드 4-way, 4워드 라인 캐시로 바꿔 실기 CPU 읽기가 프레임당 34k 에서 49~51k(MAME ~50k)로 돌아왔습니다.
- **스프라이트 1픽셀 어긋남, 페이드 중 밝기 1단계.** MAME 상태를 RTL 에 넣는 시뮬레이션 대조에서 코요테·파란 스테이지 7프레임이 전부 76,800 픽셀 일치합니다(폭포 구간 510 프레임도 일치).
- **OSD 설정 저장 유지.** 이전에는 `Save settings` 로 저장해도 다음 실행 때 코어가 `.mra` 기본값을 다시 올려 저장값을 덮어썼습니다(MiSTer 는 저장 파일을 ROM 로드 전에 읽고, 코어가 보낸 status 로 128비트 전체를 교체합니다). 이제 저장된 설정이 있으면 기본값을 올리지 않습니다. 실기에서 저장 파일 값이 화면에 반영되는 것을 확인했습니다.

### 일정

| 날짜 | 이정표 |
|---|---|
| 2026-09-01 | MAME 드라이버 전수 조사 후 RTL 착수. 같은 날 합성·fit 통과, 실기에서 68000 부팅 확인 |
| 2026-09-01 | 사운드 보드(Z80 + YM2151 + OKI M6295) 편입, fg / bg0 / bg1 레이어 배선 |
| 2026-09-02 | 실기에서 버전 배너, TECHNOS 로고, 타이틀 화면, 어트랙트 데모 표시 |
| 2026-09-03 | 1차 완성 기준 다섯 가지 충족. 화면 반전(DIP SW1:6)과 워치독 구현 |
| 2026-09-04 | 클론 세트 두 개 추가, 배포용 `.mra` 정리, 실제 플레이에서 나온 결함 수정 |
| 2026-09-05 ~ 07 | 사운드 결함 추적. 2026-09-07 신고자 본인이 귀로 "소리 정상" 확인 |
| 2026-09-09 | MiSTer 표준 OSD 구성으로 통일, 세트별 버튼 구성과 빙의 매크로 정리 |
| 2026-10-06 | 빙의(펀치+킥) 매크로 버튼 제거 — 배포본에는 편의 핫키를 두지 않음. 실기에서 3세트 확인 |

### 블록별 구현

- **CPU** — 68000 은 사이클 정확도의 fx68k, Z80 은 T80 을 사용합니다.
  56 MHz 단일 클럭 도메인에서 두 CPU 의 클럭 인에이블을 합성해 냅니다.
  인터럽트는 MAME 와 같은 비율(프레임당 레벨 2 17회 + vblank 1회)로 실기에서
  측정됐습니다.
- **메모리** — 프로그램·그래픽·샘플 ROM 전체(약 14.7 MB)는 SDRAM 에 두고,
  뱅크별로 행을 열어 두는 SDRAM 컨트롤러, 클라이언트 중재기, 68000·Z80 용
  ROM 캐시를 직접 작성했습니다. Z80 프로그램 ROM 은 최종적으로 BRAM 으로
  옮겼습니다.
- **비디오** — CRTC(448×272 토털), 타일맵 엔진, fg 텍스트 레이어, 스프라이트
  엔진, 팔레트, 우선순위 합성. 타일 레이어는 한 라인 안에서 같은 타일 행을
  다시 읽지 않도록 타일 번호 기준 캐시를 갖고, 스프라이트는 다운로드 시점에
  한 행의 다섯 비트플레인을 연속된 다섯 워드로 재배치해 페치 횟수를 줄였습니다.
  스프라이트 RAM 은 BRAM 에 이중 버퍼로 둡니다.
- **사운드** — YM2151 은 jt51, OKI M6295 는 jt6295 를 사용합니다. OKI 앞에
  샘플 캐시를 두고, BGM(YM2151)과 효과음(M6295) 음량을 OSD 에서 각각 조절할 수
  있습니다(기본값 MAME ×1).
- **입력·DIP·워치독** — DIP 는 `.mra` 의 `<switches>` 로 세트별 기본값을
  싣습니다. 워치독 주기는 두 레퍼런스 어디에도 없어서 MAME 를 178초 돌려
  게임의 실제 워치독 갱신 간격(최악 25프레임)을 재고 그보다 넉넉하게 잡았습니다.
- **화면 반전** — MAME 는 타일맵만 뒤집고 FBNeo 는 구현하지 않아 두 레퍼런스가
  갈라집니다. 이 코어는 기판처럼 비디오 카운터를 반전시켜 화면 전체를 뒤집으며,
  반전 프레임이 원래 프레임의 정확한 180° 회전인지로 검증했습니다.

### 풀어 낸 주요 문제

- **메모리 대역폭.** 처음 실기에 올렸을 때 fg 레이어는 한 라인도 그리지
  못했습니다. 측정해 보니 SDRAM 읽기가 전송이 아니라 행 전환에 시간을 쓰고
  있었고, 뱅크별 행 유지, 중재기의 연속 그랜트, 타일 행 캐시, 스프라이트 ROM
  재배치를 차례로 넣어 네 레이어 모두 매 라인 272/272 를 완주하게 했습니다.
- **스프라이트 줄무늬.** 라인버퍼의 1비트 세대 태그가 네 줄마다 한 바퀴 돌아와
  지워졌어야 할 픽셀이 4줄 주기로 되살아났습니다. MAME 의 VRAM 덤프와 대조해
  원인을 특정하고 고쳤습니다.
- **스프라이트 색.** 화면 오른쪽 1/5 이 그늘져 보이던 문제는 스프라이트 워드 4
  의 비트 0 이 색이 아니라 X 좌표 최상위 비트였기 때문입니다.
- **타일맵 좌표계.** MAME 의 타일맵은 화면 행이 아니라 원래 라인 번호 기준이라,
  첫 표시 라인이 맵의 8번째 행을 보여 줘야 합니다.
- **사운드.** 효과음 무음(배선되지 않은 캐시 데이터 버스), 절반이 묵은 값인 OKI
  바이트 래치, YM2151 쓰기 스트로브 정렬, OKI 출력 시프트(`<<4`)를 차례로
  바로잡았습니다. 마지막까지 남았던 "물에 젖은 듯 먹먹한 소리"는 디코더가 아니라
  게인 체인 문제였습니다. OKI 디코더 출력은 MAME 의 `okiadpcm.cpp` 와 16,478
  샘플 중 16,477 개가 비트 단위로 일치합니다.
- **클론 세트.** 클론 `.mra` 가 부모 세트의 zip 을 지정하지 않으면 ROM 15개 중
  10개를 찾지 못해 부팅 검사에서 무한 리셋됩니다. 미국판은 MAME 의
  `PORT_MODIFY("DSW2")` 대로 자체 DIP 기본값을 갖습니다.
- **버튼 구성.** World·Japan 은 3버튼(빙의 = 펀치+킥 동시), US 만 전용 빙의
  버튼이 있는 6버튼입니다. MAME 와 FBNeo 가 여기서 갈라졌고, 실기에서 World 가
  펀치+킥으로 빙의하는 것을 확인해 MAME 쪽을 따랐습니다. 3버튼 세트에는 두 버튼을
  한 번에 누르는 매크로 버튼을 두었지만, 2026-10-06 배포본에서는 뺐습니다(편의 기능 대신
  기판과 같은 조작). 3버튼 세트의 빙의는 펀치+킥을 함께 누르면 됩니다.

## 감사의 말과 사용한 코드

먼저 **MAME 팀**에 깊이 감사드립니다. 이 코어는 MAME 의 `shadfrce` 드라이버와
그 주석에 남겨진 기판 정보 — 클럭마다 붙은 "verified on PCB", 크리스털 실측값,
메모리 맵, 그래픽 디코드, ROM 구성 — 위에서 시작했습니다. 수십 년 동안 하드웨어를
기록하고 보존해 온 그 작업이 없었다면 이 코어는 존재할 수 없었습니다.

- https://www.mamedev.org/
- https://github.com/mamedev/mame

### 함께 빌드되는 서드파티 코드

| 이름 | 용도 | 저자 | 라이선스 | 출처 | 사용한 파일 | 수정 여부 |
|---|---|---|---|---|---|---|
| fx68k | 메인 CPU (68000) | Jorge Cwik | GPL-3.0 | [ijor/fx68k](https://github.com/ijor/fx68k) @ `0602ee4627b10f301298f2673d826cdd6baa9327` | `fx68k.sv`, `fx68kAlu.sv`, `uaddrPla.sv`, `microrom.mem`, `nanorom.mem` | **수정함** — `fx68k.sv` 에 읽기 전용 디버그 관측 포트(`dbg_d7`) 하나를 추가했습니다. 동작 변화 없음, 소스에 `// LOCAL:` 로 표시 |
| T80 | 사운드 CPU (Z80) | Daniel Wallner, MiSTer-devel(Sorgelig 외) | BSD-3-Clause 계열 | [MiSTer-devel/T80](https://github.com/MiSTer-devel/T80) @ `830fd0315f0af5cdbcb0e703f1cea3ce4e91f538` | `T80.vhd`, `T80_ALU.vhd`, `T80_MCode.vhd`, `T80_Pack.vhd`, `T80_Reg.vhd`, `T80pa.vhd` | 수정 없음 |
| JT51 | YM2151 FM 음원 | Jose Tejada Gomez (jotego) | GPL-3.0 | [jotego/jt51](https://github.com/jotego/jt51) @ `985a573dcfc1ff135553a39f7eae21d18ba57cbe` | `jt51.v` 외 `jt51_*.v` 21개 (upstream `hdl/jt51.qip` 목록 기준) | 수정 없음 |
| JT6295 | OKI M6295 ADPCM | Jose Tejada Gomez (jotego) | GPL-3.0 | [jotego/jt6295](https://github.com/jotego/jt6295) @ `7d76b0be8cd8f85f3ae741178c9830b20e2071a1` | `jt6295.v`, `jt6295_acc.v`, `jt6295_adpcm.v`, `jt6295_ctrl.v`, `jt6295_rom.v`, `jt6295_serial.v`, `jt6295_sh_rst.v`, `jt6295_timing.v`, `jt12_comb.v`, `jt12_interpol.v` | 수정 없음 (`INTERPOL=0` 으로 사용) |
| MiSTer framework | HPS 연동, 비디오 스케일러, OSD, 오디오 출력 | MiSTer-devel 기여자들 | 파일별 라이선스 (GPL 계열 포함) | [MiSTer-devel/Template_MiSTer @ `54ac838e019d7fa07fbb40677a104cd6620d15c3` (2026-08-17, `sys/` 내용 일치로 식별)](https://github.com/MiSTer-devel/Template_MiSTer) | `sys/` 디렉터리 | `sys.tcl` 의 경로 해석 두 줄만 변경 |

- **Jorge Cwik** 님, 사이클 단위로 정확한 68000 코어 fx68k 를 공개해 주셔서
  감사합니다. 이 게임의 메인 CPU 는 처음부터 끝까지 fx68k 로 돌아갑니다.
- **Daniel Wallner** 님과 T80 을 오랫동안 유지해 온 **MiSTer-devel** 기여자 여러분께
  감사드립니다.
- **Jose Tejada Gomez (jotego)** 님, JT51 과 JT6295 덕분에 이 기판의 소리를 낼 수
  있었습니다. 특히 JT6295 는 MAME 와 비트 단위로 대조할 수 있을 만큼 정확했습니다.
- **MiSTer-devel** 과 **Sorgelig** 님을 비롯한 MiSTer 프로젝트 기여자 여러분께,
  이 모든 것을 올려놓을 플랫폼을 만들어 주셔서 감사드립니다.

### 참고한 MAME 소스

MAME 소스는 하드웨어 사실을 확인하는 참고 자료로 읽었고, **코드는 옮겨 오지
않았습니다.** RTL 주석에서 인용한 파일은 다음과 같습니다.

| MAME 파일 | 라이선스 | copyright-holders | 참고한 내용 |
|---|---|---|---|
| `src/mame/technos/shadfrce.cpp` | BSD-3-Clause | David Haywood | 메모리 맵, 클럭, 인터럽트, 화면 타이밍, 그래픽 디코드, 스프라이트 속성, ROM 구성, 입력 포트와 DIP 기본값, 사운드 라우팅 |
| `src/devices/sound/okim6295.cpp` | BSD-3-Clause | Mirko Buffoni, Aaron Giles | M6295 명령 처리와 출력 스케일 |
| `src/emu/drawgfx.cpp` | BSD-3-Clause | Nicola Salmoria, Aaron Giles | 스프라이트 우선순위 마스크(`prio_transpen`)의 동작 |

이 밖에 `src/devices/sound/okiadpcm.cpp` 는 시뮬레이션에서 OKI 디코더 출력을
비교하는 기준으로만 사용했습니다(배포 RTL 에는 포함되지 않음).

### FBNeo

[FinalBurn Neo](https://github.com/finalburnneo/FBNeo) 의 `d_shadfrce.cpp` 를
**사실 교차확인용으로만** 읽었습니다(스프라이트 디코드, OKI 재시작 규칙, 버튼
구성, 화면 반전 처리 등). **FBNeo 코드는 한 줄도 가져오지 않았습니다.**
FBNeo 의 라이선스는 GPLv3 가 허용하지 않는 제약을 덧붙이므로, 앞으로도 이
코어에 FBNeo 코드가 들어올 수 없습니다. 이 자리를 빌려 FBNeo 개발자 여러분께도
감사드립니다.

## 라이선스

이 코어는 전체로서 **GPL-3.0** 으로 배포합니다. GPL-3.0 인 fx68k 가 함께
컴파일되기 때문입니다. 저장소의 `LICENSE` 파일은 GPL-3.0 전문입니다.

- 서드파티 파일은 각자의 저작권·라이선스 헤더를 그대로 유지합니다. T80 은
  BSD-3-Clause 계열로 GPL-3.0 과 호환되며, JT51·JT6295 는 GPL-3.0 입니다.
- 수정한 서드파티 파일(`fx68k.sv`)에는 GPL-3.0 §5(a) 에 따라 수정 사실이
  표시되어 있습니다.
- **ROM 데이터는 포함하지 않습니다.** 게임을 실행하려면 직접 소유한 ROM 이
  필요합니다.
- *Shadow Force* 는 각 권리자의 상표입니다.

## 알려진 제한사항

- **미국판(`shadfrceu`)은 실기에서 플레이해 본 기록이 없습니다.**
- **OKI M6295 재시작 규칙.** 이미 재생 중인 보이스에 들어온 시작 명령은 원래
  칩에서 무시되어야 하지만(MAME·FBNeo 공통), 현재 코어는 재시작합니다. 효과음이
  서로 겹치는 방식이 원본과 다를 수 있습니다. 음색 자체에는 영향이 거의 없습니다.
- **ROM 페처의 주소 래치.** 진행 중인 페치 도중 주소가 바뀌면 묵은 워드를
  받아들일 수 있는 경로가 있습니다. 실기의 실제 지연에서는 발생하지 않는 것으로
  측정됐지만 원리적으로는 결함입니다.
- **최종 믹싱 게인**은 MAME 의 `add_route` 값을 따른 것이며, 실제 기판의 합산 회로는
  조사하지 않았습니다.
- **화면 반전**은 기판 동작을 추정해 구현한 것으로, MAME 와 직접 대조할 수
  없습니다.
- Analogue Pocket 버전은 아직 없습니다.
