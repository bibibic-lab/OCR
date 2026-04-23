package kr.ocr.upload

import org.assertj.core.api.Assertions.assertThat
import org.assertj.core.api.Assertions.assertThatThrownBy
import org.junit.jupiter.api.BeforeEach
import org.junit.jupiter.api.Nested
import org.junit.jupiter.api.Test
import org.junit.jupiter.api.extension.ExtendWith
import org.mockito.Mock
import org.mockito.Mockito.never
import org.mockito.Mockito.verify
import org.mockito.Mockito.`when`
import org.mockito.junit.jupiter.MockitoExtension

/**
 * TokenizationService 단위 테스트.
 *
 * FpeClient 를 Mock 으로 격리하여 RRN 패턴 탐지·치환 로직만 검증한다.
 * 네트워크·DB 의존 없음 → 빠른 단위 테스트.
 */
@ExtendWith(MockitoExtension::class)
class TokenizationServiceTest {

    @Mock
    private lateinit var fpeClient: FpeClient

    private lateinit var service: TokenizationService

    /** FPE 활성 기본 설정 */
    private val enabledProps = OcrProperties(
        s3 = OcrProperties.S3Props(
            endpoint = "http://localhost",
            region = "us-east-1",
            bucket = "test",
        ),
        ocrWorker = OcrProperties.OcrWorkerProps(baseUrl = "http://localhost"),
        fpe = OcrProperties.FpeProps(enabled = true, serviceUrl = "http://fpe-test"),
    )

    /** FPE 비활성 설정 */
    private val disabledProps = enabledProps.copy(
        fpe = OcrProperties.FpeProps(enabled = false),
    )

    @BeforeEach
    fun setUp() {
        service = TokenizationService(fpeClient, enabledProps)
    }

    // ─────────────────────────────────────────────────────────────────────────
    // 1. RRN 없음 → fpeClient 호출 안 함
    // ─────────────────────────────────────────────────────────────────────────
    @Test
    fun `RRN이 없는 items는 fpeClient를 호출하지 않고 원본을 반환한다`() {
        val items = listOf(
            OcrItem(text = "홍길동", confidence = 0.99),
            OcrItem(text = "주민등록증", confidence = 0.98),
        )

        val (result, count) = service.tokenizeSensitiveFields(items)

        assertThat(count).isEqualTo(0)
        assertThat(result).isEqualTo(items)
        verify(fpeClient, never()).tokenizeBatch(any())
    }

    // ─────────────────────────────────────────────────────────────────────────
    // 2. RRN 1건 탐지 → 토큰으로 교체
    // ─────────────────────────────────────────────────────────────────────────
    @Test
    fun `RRN 1건이 포함된 items를 토큰으로 교체한다`() {
        val items = listOf(
            OcrItem(text = "성명: 홍길동", confidence = 0.99),
            OcrItem(text = "주민등록번호: 900101-1234567", confidence = 0.98),
        )

        `when`(fpeClient.tokenizeBatch(listOf(FpeTokenizeItem("rrn", "900101-1234567"))))
            .thenReturn(
                FpeBatchResponse(tokens = listOf(FpeTokenResult("rrn", "123456-7654321", "uuid-1")))
            )

        val (result, count) = service.tokenizeSensitiveFields(items)

        assertThat(count).isEqualTo(1)
        assertThat(result[0].text).isEqualTo("성명: 홍길동")           // 변경 없음
        assertThat(result[1].text).isEqualTo("주민등록번호: 123456-7654321") // 치환됨
        assertThat(result[1].text).doesNotContain("900101-1234567")
    }

    // ─────────────────────────────────────────────────────────────────────────
    // 3. 동일 RRN 중복 → 고유값만 1회 배치 요청
    // ─────────────────────────────────────────────────────────────────────────
    @Test
    fun `동일 RRN이 여러 item에 등장해도 fpeClient는 1회만 호출된다`() {
        val rrn = "850315-2345678"
        val token = "987654-3210987"
        val items = listOf(
            OcrItem(text = "앞면: $rrn"),
            OcrItem(text = "뒷면: $rrn"),
        )

        `when`(fpeClient.tokenizeBatch(listOf(FpeTokenizeItem("rrn", rrn))))
            .thenReturn(FpeBatchResponse(tokens = listOf(FpeTokenResult("rrn", token, "uuid-2"))))

        val (result, count) = service.tokenizeSensitiveFields(items)

        assertThat(count).isEqualTo(1)    // 고유 1건
        assertThat(result[0].text).contains(token)
        assertThat(result[1].text).contains(token)
        assertThat(result[0].text).doesNotContain(rrn)
        assertThat(result[1].text).doesNotContain(rrn)
    }

    // ─────────────────────────────────────────────────────────────────────────
    // 4. 다중 고유 RRN → 단일 배치 호출
    // ─────────────────────────────────────────────────────────────────────────
    @Test
    fun `여러 고유 RRN을 단일 배치로 토큰화한다`() {
        val rrn1 = "900101-1234567"
        val rrn2 = "850315-2345678"
        val items = listOf(
            OcrItem(text = rrn1),
            OcrItem(text = rrn2),
        )

        `when`(fpeClient.tokenizeBatch(
            listOf(FpeTokenizeItem("rrn", rrn1), FpeTokenizeItem("rrn", rrn2))
        )).thenReturn(
            FpeBatchResponse(tokens = listOf(
                FpeTokenResult("rrn", "111111-1111111", "uuid-3"),
                FpeTokenResult("rrn", "222222-2222222", "uuid-4"),
            ))
        )

        val (result, count) = service.tokenizeSensitiveFields(items)

        assertThat(count).isEqualTo(2)
        assertThat(result[0].text).doesNotContain(rrn1)
        assertThat(result[1].text).doesNotContain(rrn2)
    }

    // ─────────────────────────────────────────────────────────────────────────
    // 5. 패턴 경계 검증 — 전화번호·카드번호는 매칭 안 됨
    // ─────────────────────────────────────────────────────────────────────────
    @Test
    fun `전화번호 형식은 RRN 패턴에 매칭되지 않는다`() {
        val items = listOf(
            OcrItem(text = "전화: 010-1234-5678"),    // 3-4-4: RRN 아님
            OcrItem(text = "팩스: 02-123-4567"),       // 길이 불일치
        )

        val (result, count) = service.tokenizeSensitiveFields(items)

        assertThat(count).isEqualTo(0)
        assertThat(result).isEqualTo(items)
        verify(fpeClient, never()).tokenizeBatch(any())
    }

    // ─────────────────────────────────────────────────────────────────────────
    // 6. FPE 비활성 → no-op
    // ─────────────────────────────────────────────────────────────────────────
    @Test
    fun `FPE 비활성화 시 RRN이 있어도 원본을 그대로 반환한다`() {
        val serviceDisabled = TokenizationService(fpeClient, disabledProps)
        val items = listOf(OcrItem(text = "900101-1234567"))

        val (result, count) = serviceDisabled.tokenizeSensitiveFields(items)

        assertThat(count).isEqualTo(0)
        assertThat(result[0].text).isEqualTo("900101-1234567")
        verify(fpeClient, never()).tokenizeBatch(any())
    }

    // ─────────────────────────────────────────────────────────────────────────
    // 7. fpeClient 오류 → FpeCallException 전파 (저장 차단)
    // ─────────────────────────────────────────────────────────────────────────
    @Test
    fun `fpeClient가 오류를 던지면 FpeCallException이 전파된다`() {
        val items = listOf(OcrItem(text = "900101-1234567"))

        `when`(fpeClient.tokenizeBatch(any()))
            .thenThrow(FpeCallException("fpe-service 연결 거부"))

        assertThatThrownBy { service.tokenizeSensitiveFields(items) }
            .isInstanceOf(FpeCallException::class.java)
            .hasMessageContaining("fpe-service 연결 거부")
    }

    // ─────────────────────────────────────────────────────────────────────────
    // 8. 응답 수 불일치 → FpeCallException
    // ─────────────────────────────────────────────────────────────────────────
    @Test
    fun `fpeClient 응답 토큰 수가 요청 수와 다르면 FpeCallException이 발생한다`() {
        val items = listOf(
            OcrItem(text = "900101-1234567"),
            OcrItem(text = "850315-2345678"),
        )

        `when`(fpeClient.tokenizeBatch(any()))
            .thenReturn(FpeBatchResponse(tokens = listOf(  // 2건 요청, 1건 응답 → 불일치
                FpeTokenResult("rrn", "111111-1111111", "uuid-5"),
            )))

        assertThatThrownBy { service.tokenizeSensitiveFields(items) }
            .isInstanceOf(FpeCallException::class.java)
            .hasMessageContaining("불일치")
    }

    // ─────────────────────────────────────────────────────────────────────────
    // 9. RRN 경계 패턴 — 앞뒤 숫자에 붙어있으면 매칭 안 됨 (\b 검증)
    // ─────────────────────────────────────────────────────────────────────────
    @Test
    fun `RRN 패턴은 단어 경계를 요구한다 (앞뒤 숫자가 붙으면 매칭 안 됨)`() {
        // 14자리 이상이면 \b 때문에 매칭 안 됨
        val items = listOf(OcrItem(text = "1900101-12345678"))  // 앞에 1 추가

        val (_, count) = service.tokenizeSensitiveFields(items)

        assertThat(count).isEqualTo(0)
        verify(fpeClient, never()).tokenizeBatch(any())
    }

    // Mockito any() 헬퍼 (null-safe)
    private fun <T> any(): T {
        org.mockito.Mockito.any<T>()
        @Suppress("UNCHECKED_CAST")
        return null as T
    }
}
