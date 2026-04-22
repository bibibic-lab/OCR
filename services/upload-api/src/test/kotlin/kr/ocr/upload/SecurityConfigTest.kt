package kr.ocr.upload

import org.junit.jupiter.api.Test
import org.springframework.beans.factory.annotation.Autowired
import org.springframework.boot.test.autoconfigure.web.servlet.AutoConfigureMockMvc
import org.springframework.boot.test.context.SpringBootTest
import org.springframework.security.oauth2.jwt.JwtDecoder
import org.springframework.test.context.ActiveProfiles
import org.springframework.boot.test.mock.mockito.MockBean
import org.springframework.test.web.servlet.MockMvc
import org.springframework.test.web.servlet.get

/**
 * SecurityConfig 통합 테스트.
 *
 * 목적:
 *  1. 보호된 경로(예: /documents/test)에 비인증 요청 → HTTP 401 반환 확인
 *  2. 공개 actuator 경로(/actuator/health/liveness) → HTTP 200 반환 확인
 *
 * 전략:
 *  - @ActiveProfiles("test"): application-test.yml이 로드되어
 *    DB/Flyway/jOOQ 자동설정이 제외되고 JWK URI가 localhost:0으로 오버라이드됨.
 *  - @MockBean(JwtDecoder::class): JwtDecoder를 목으로 교체해 실제 Keycloak JWKS
 *    엔드포인트 호출 없이 컨텍스트가 기동됨. (Spring Boot 3.2.5 기준. 3.4+는 @MockitoBean)
 *  - 비인증 요청에서는 JwtDecoder가 호출되지 않으므로 목 반환값 설정 불필요.
 */
@SpringBootTest
@AutoConfigureMockMvc
@ActiveProfiles("test")
class SecurityConfigTest {

    @Autowired
    private lateinit var mockMvc: MockMvc

    @MockBean
    private lateinit var jwtDecoder: JwtDecoder

    @Test
    fun `비인증 GET documents test 는 401 을 반환한다`() {
        mockMvc.get("/documents/test")
            .andExpect {
                status { isUnauthorized() }
            }
    }

    @Test
    fun `actuator health liveness 는 인증 없이 200 을 반환한다`() {
        mockMvc.get("/actuator/health/liveness")
            .andExpect {
                status { isOk() }
            }
    }
}
