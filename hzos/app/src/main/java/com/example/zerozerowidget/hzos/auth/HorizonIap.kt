package com.example.zerozerowidget.hzos.auth

import android.util.Log
import horizon.core.android.common.pagination.ext.initialPage
import horizon.core.android.common.pagination.ext.nextPage
import horizon.platform.iap.Iap
import horizon.platform.iap.IapException
import horizon.platform.users.Users
import kotlinx.coroutines.CoroutineScope

/**
 * Thin wrapper over the Horizon Platform SDK In-App Purchase package.
 *
 * Same shape as [HorizonAuth]: the no-arg `Iap()`/`Users()` resolve the
 * shared connection [HorizonAuth.connect] establishes, and everything here
 * degrades to null/empty/false when the Platform SDK is absent — the UI
 * then says subscriptions need setup instead of crashing.
 *
 * Inactive until a Platform app ID is configured (`platformAppId` in
 * hzos/local.properties → BuildConfig), same gate as phone sign-in.
 *
 * Privacy: [loggedInUserId] returns the *app-scoped* user id, which is
 * stable for this app and meaningless outside it. That is the value the
 * Worker's Meta subscription sync keys on — never the cross-app Oculus id.
 */
class HorizonIap(
    private val scope: CoroutineScope,
    val appId: String,
) {
    data class ProductOffer(
        val sku: String,
        val name: String,
        val formattedPrice: String,
    )

    val isAvailable: Boolean get() = appId.isNotBlank()

    /** Catalog entries for [skus], with localized prices. Empty on any failure. */
    suspend fun fetchProducts(skus: List<String>): List<ProductOffer> {
        if (!isAvailable || skus.isEmpty()) return emptyList()
        return try {
            val out = mutableListOf<ProductOffer>()
            val paged = Iap().getProductsBySku(scope, skus)
            paged.initialPage()
            while (true) {
                out += paged.getFetchedPages().flatMap { page ->
                    page.contents.map { product ->
                        ProductOffer(
                            sku = product.sku,
                            name = product.name,
                            formattedPrice = product.formattedPrice,
                        )
                    }
                }
                if (!paged.hasNextPage()) break
                paged.nextPage()
            }
            out
        } catch (e: Exception) {
            Log.e(TAG, "fetchProducts failed: ${e.javaClass.simpleName}: ${e.message}")
            emptyList()
        }
    }

    /**
     * Runs the system checkout for [sku]. Ok SKU on success; a human
     * message (cancel included) on failure — the caller shows it as-is.
     */
    suspend fun checkout(sku: String): Result<String> {
        if (!isAvailable) return Result.failure(IllegalStateException("Platform app ID not configured."))
        return try {
            Result.success(Iap().launchCheckoutFlow(sku).sku)
        } catch (e: IapException) {
            Log.e(TAG, "checkout failed: ${e.displayableMessage}")
            Result.failure(IllegalStateException(e.displayableMessage))
        } catch (e: Exception) {
            Log.e(TAG, "checkout failed: ${e.javaClass.simpleName}: ${e.message}")
            Result.failure(e)
        }
    }

    /** SKUs the Meta account currently owns. Empty on any failure. */
    suspend fun ownedSkus(): Set<String> {
        if (!isAvailable) return emptySet()
        return try {
            Iap().getViewerPurchases().map { it.sku }.toSet()
        } catch (e: Exception) {
            Log.e(TAG, "ownedSkus failed: ${e.javaClass.simpleName}: ${e.message}")
            emptySet()
        }
    }

    /** App-scoped id of the signed-in Meta account. Null when unreadable. */
    suspend fun loggedInUserId(): String? {
        if (!isAvailable) return null
        return try {
            Users().getLoggedInUser().id.takeIf { it.isNotBlank() }
        } catch (e: Exception) {
            Log.e(TAG, "loggedInUserId failed: ${e.javaClass.simpleName}: ${e.message}")
            null
        }
    }

    companion object {
        private const val TAG = "HorizonIap"
    }
}
