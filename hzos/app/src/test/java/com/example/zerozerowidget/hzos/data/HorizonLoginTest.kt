package com.example.zerozerowidget.hzos.data

import com.example.zerozerowidget.hzos.auth.MetaIdentity
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The Horizon sign-in matrix, without a device: returning user, create,
 * join, proof retry (and its cap), account switch, and browser approval.
 * Network and Platform SDK enter only as injected lambdas.
 */
class HorizonLoginTest {

    private val identity = MetaIdentity("meta-user-1", "proof-0")

    @Test
    fun `returning user signs in and stores the token against the Meta id`() = runBlocking {
        val outcome = runHorizonSignIn(
            identity = { identity },
            request = { _, _, choice ->
                assertEquals(null, choice)
                201 to """{"status":"signed_in","token":"zwa_new"}"""
            },
        )
        assertEquals(HorizonOutcome.SignedIn("zwa_new", "meta-user-1"), outcome)
    }

    @Test
    fun `create choice is sent through and signs in`() = runBlocking {
        val seen = mutableListOf<String?>()
        val outcome = runHorizonSignIn(
            identity = { identity },
            request = { _, _, choice ->
                seen += choice
                201 to """{"status":"signed_in","token":"zwa_created"}"""
            },
            choice = "create",
        )
        assertEquals(listOf("create"), seen)
        assertEquals(HorizonOutcome.SignedIn("zwa_created", "meta-user-1"), outcome)
    }

    @Test
    fun `choice_required asks instead of choosing`() = runBlocking {
        val outcome = runHorizonSignIn(
            identity = { identity },
            request = { _, _, _ -> 200 to """{"status":"choice_required","choices":["create","join_apple"]}""" },
        )
        assertEquals(HorizonOutcome.NeedChoice, outcome)
    }

    @Test
    fun `join_apple answer carries the device code for delivery and polling`() = runBlocking {
        val outcome = runHorizonSignIn(
            identity = { identity },
            request = { _, _, choice ->
                assertEquals("join_apple", choice)
                201 to """{"device_code":"dc","user_code":"ABCD-EFGH","verification_uri":"https://h/app/device","expires_in":600,"interval":5}"""
            },
            choice = "join_apple",
        )
        val join = outcome as HorizonOutcome.JoinCode
        assertEquals("ABCD-EFGH", join.code.userCode)
        assertEquals(5, join.code.intervalSeconds)
    }

    @Test
    fun `burned proof retries once with a fresh proof`() = runBlocking {
        val proofs = mutableListOf<String>()
        val identities = listOf(MetaIdentity("meta-user-1", "proof-stale"), MetaIdentity("meta-user-1", "proof-fresh")).iterator()
        val outcome = runHorizonSignIn(
            identity = { identities.next() },
            request = { _, proof, _ ->
                proofs += proof
                if (proof == "proof-stale") {
                    409 to """{"error":"User proof has already been used"}"""
                } else {
                    201 to """{"status":"signed_in","token":"zwa_retry"}"""
                }
            },
        )
        assertEquals(listOf("proof-stale", "proof-fresh"), proofs)
        assertEquals(HorizonOutcome.SignedIn("zwa_retry", "meta-user-1"), outcome)
    }

    @Test
    fun `proof retry is capped at one`() = runBlocking {
        var calls = 0
        val outcome = runHorizonSignIn(
            identity = { MetaIdentity("meta-user-1", "proof-$calls") },
            request = { _, _, _ ->
                calls++
                409 to """{"error":"User proof has already been used"}"""
            },
        )
        assertEquals(2, calls)
        assertTrue(outcome is HorizonOutcome.Failed)
    }

    @Test
    fun `unreadable Meta identity fails before any request`() = runBlocking {
        var calls = 0
        val outcome = runHorizonSignIn(
            identity = { null },
            request = { _, _, _ -> calls++; 201 to "{}" },
        )
        assertEquals(0, calls)
        assertTrue(outcome is HorizonOutcome.Failed)
    }

    @Test
    fun `server states map to guidance, not codes`() {
        assertEquals(
            HorizonOutcome.Failed("This Worker is too old for Horizon sign-in — update it."),
            (classifyHorizonSignIn("u", 404, "Not Found", 0) as HorizonStep.Done).outcome,
        )
        assertEquals(
            HorizonOutcome.Failed("Meta could not verify this headset user."),
            (classifyHorizonSignIn("u", 401, """{"error":"nope"}""", 0) as HorizonStep.Done).outcome,
        )
        assertEquals(
            HorizonOutcome.Failed("Horizon sign-in isn't configured on this server."),
            (classifyHorizonSignIn("u", 503, "{}", 0) as HorizonStep.Done).outcome,
        )
        assertEquals(
            HorizonOutcome.Failed("Custom problem."),
            (classifyHorizonSignIn("u", 400, """{"error":"Custom problem."}""", 0) as HorizonStep.Done).outcome,
        )
    }

    @Test
    fun `request body omits a null choice`() {
        val bare = horizonSignInBody("u", "p", null)
        assertTrue(bare.contains("\"userId\":\"u\""))
        assertTrue(!bare.contains("choice"))
        val chosen = horizonSignInBody("u", "p", "create")
        assertTrue(chosen.contains("\"choice\":\"create\""))
    }

    @Test
    fun `account switch only fires on present and different ids`() {
        assertEquals(false, isMetaUserSwitch("", "someone"))
        assertEquals(false, isMetaUserSwitch("a", null))
        assertEquals(false, isMetaUserSwitch("a", ""))
        assertEquals(false, isMetaUserSwitch("a", "a"))
        assertEquals(true, isMetaUserSwitch("a", "b"))
    }

    @Test
    fun `browser approval echoes the decision and names failures`() {
        assertEquals("Browser sign-in approved.", describeBrowserApproval(200, """{"ok":true}""", true))
        assertEquals("Browser sign-in denied.", describeBrowserApproval(200, """{"ok":true}""", false))
        assertEquals("That code is invalid or expired.", describeBrowserApproval(404, "{}", true))
        assertEquals("That code has already been used.", describeBrowserApproval(409, "{}", true))
        assertEquals(
            "This account isn't linked to a Horizon identity.",
            describeBrowserApproval(403, "{}", true),
        )
    }
}
