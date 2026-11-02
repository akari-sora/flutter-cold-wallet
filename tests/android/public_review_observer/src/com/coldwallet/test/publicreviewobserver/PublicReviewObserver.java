package com.coldwallet.test.publicreviewobserver;

import android.app.Instrumentation;
import android.app.UiAutomation;
import android.graphics.Rect;
import android.os.Bundle;
import android.os.SystemClock;
import android.text.InputType;
import android.view.accessibility.AccessibilityNodeInfo;
import org.json.JSONArray;
import org.json.JSONObject;
import java.nio.charset.StandardCharsets;
import java.util.ArrayDeque;

/** Read-only, self-targeted instrumentation. No activities, input, screenshots, or disk writes. */
public final class PublicReviewObserver extends Instrumentation {
    private static final int MAX_NODES = 512;
    private static final int MAX_DEPTH = 32;
    private static final int MAX_FIELD_CHARS = 16384;
    private static final int MAX_TEXT_BYTES = 131072;
    private static final int MAX_OUTPUT_BYTES = 196608;

    private static final class Pending {
        final AccessibilityNodeInfo node;
        final int depth;
        Pending(AccessibilityNodeInfo node, int depth) { this.node = node; this.depth = depth; }
    }

    private static final class Refusal extends Exception {
        private static final long serialVersionUID = 1L;
        final String code;
        Refusal(String code) { this.code = code; }
    }

    @Override public void onCreate(Bundle arguments) {
        super.onCreate(arguments);
        start();
    }

    @Override public void onStart() {
        Bundle result = new Bundle();
        try {
            result.putString("public_review_json", observe().toString());
            finish(0, result);
        } catch (Refusal refusal) {
            refuse(result, refusal.code);
        } catch (Throwable failure) {
            // Exception messages may include UI content. Return a fixed code only.
            refuse(result, "OBSERVER_FAILED");
        }
    }

    private void refuse(Bundle result, String code) {
        result.putString("public_review_json", "{\"status\":\"REFUSED\",\"reason\":\"" + code + "\"}");
        finish(1, result);
    }

    @SuppressWarnings("deprecation") // recycle remains required on the supported API 26-32 runtimes.
    private JSONObject observe() throws Exception {
        UiAutomation automation = getUiAutomation(UiAutomation.FLAG_DONT_SUPPRESS_ACCESSIBILITY_SERVICES);
        if (automation == null) throw new Refusal("UI_AUTOMATION_UNAVAILABLE");
        final long rootDeadline = SystemClock.uptimeMillis() + 5000;
        AccessibilityNodeInfo root;
        while ((root = automation.getRootInActiveWindow()) == null) {
            long remaining = rootDeadline - SystemClock.uptimeMillis();
            if (remaining <= 0) throw new Refusal("NO_ACTIVE_ROOT");
            // Only wait for initial accessibility readiness; never retry another package.
            SystemClock.sleep(Math.min(50, remaining));
        }
        if (!ReviewGate.VAULT.contentEquals(orEmpty(root.getPackageName()))) {
            root.recycle();
            throw new Refusal("WRONG_ACTIVE_PACKAGE");
        }
        final int windowId = root.getWindowId();
        ArrayDeque<Pending> queue = new ArrayDeque<>();
        queue.add(new Pending(root, 0));
        JSONArray nodes = new JSONArray();
        ReviewGate gate = new ReviewGate();
        int count = 0;
        int textBytes = 0;
        try {
            while (!queue.isEmpty()) {
                Pending pending = queue.removeFirst();
                AccessibilityNodeInfo node = pending.node;
                try {
                    if (++count > MAX_NODES || pending.depth > MAX_DEPTH) throw new Refusal("TREE_LIMIT");
                    CharSequence pkg = node.getPackageName();
                    if (pkg != null && !ReviewGate.VAULT.contentEquals(pkg)) throw new Refusal("MIXED_PACKAGE_TREE");
                    // Do not request any text, description, or hint from a password node.
                    if (node.isPassword() || isPasswordInputType(node.getInputType())) throw new Refusal("PASSWORD_NODE");
                    String text = bounded(node.getText());
                    String description = bounded(node.getContentDescription());
                    String hint = bounded(node.getHintText());
                    textBytes += bytes(text) + bytes(description) + bytes(hint);
                    if (textBytes > MAX_TEXT_BYTES) throw new Refusal("TEXT_LIMIT");
                    gate.inspect(text, node.isVisibleToUser());
                    gate.inspect(description, node.isVisibleToUser());
                    gate.inspect(hint, node.isVisibleToUser());
                    if ("SECRET_SURFACE".equals(gate.rejection())) throw new Refusal("SECRET_SURFACE");
                    Rect bounds = new Rect();
                    node.getBoundsInScreen(bounds);
                    JSONObject row = new JSONObject();
                    row.put("index", count - 1);
                    row.put("depth", pending.depth);
                    row.put("text", text);
                    row.put("content_description", description);
                    row.put("hint_text", hint);
                    row.put("bounds", new JSONArray(new int[] {bounds.left, bounds.top, bounds.right, bounds.bottom}));
                    row.put("visible_to_user", node.isVisibleToUser());
                    row.put("enabled", node.isEnabled());
                    row.put("editable", node.isEditable());
                    row.put("focusable", node.isFocusable());
                    row.put("focused", node.isFocused());
                    row.put("clickable", node.isClickable());
                    row.put("scrollable", node.isScrollable());
                    row.put("selected", node.isSelected());
                    row.put("password", false);
                    nodes.put(row);
                    int children = node.getChildCount();
                    if (children > MAX_NODES || count + queue.size() + children > MAX_NODES) throw new Refusal("TREE_LIMIT");
                    for (int i = 0; i < children; i++) {
                        AccessibilityNodeInfo child = node.getChild(i);
                        if (child == null) throw new Refusal("INCOMPLETE_TREE");
                        queue.addLast(new Pending(child, pending.depth + 1));
                    }
                } finally { node.recycle(); }
            }
        } finally {
            while (!queue.isEmpty()) queue.removeFirst().node.recycle();
        }
        String rejection = gate.rejection();
        if (rejection != null) throw new Refusal(rejection);
        // Re-check the active window before releasing the in-memory snapshot.
        AccessibilityNodeInfo current = automation.getRootInActiveWindow();
        if (current == null) throw new Refusal("ACTIVE_WINDOW_CHANGED");
        if (current.getWindowId() != windowId ||
            !ReviewGate.VAULT.contentEquals(orEmpty(current.getPackageName()))) {
            current.recycle();
            throw new Refusal("ACTIVE_WINDOW_CHANGED");
        }
        // A custom Flutter provider need not implement query-by-text for content descriptions.
        // Validate the fresh tree explicitly with the same bounds and gate; emit none of it.
        ReviewGate currentGate = new ReviewGate();
        int currentCount = 0;
        int currentTextBytes = 0;
        queue.add(new Pending(current, 0));
        try {
            while (!queue.isEmpty()) {
                Pending pending = queue.removeFirst();
                AccessibilityNodeInfo node = pending.node;
                try {
                    if (++currentCount > MAX_NODES || pending.depth > MAX_DEPTH) throw new Refusal("TREE_LIMIT");
                    CharSequence pkg = node.getPackageName();
                    if (pkg != null && !ReviewGate.VAULT.contentEquals(pkg)) throw new Refusal("MIXED_PACKAGE_TREE");
                    if (node.isPassword() || isPasswordInputType(node.getInputType())) throw new Refusal("PASSWORD_NODE");
                    String text = bounded(node.getText());
                    String description = bounded(node.getContentDescription());
                    String hint = bounded(node.getHintText());
                    currentTextBytes += bytes(text) + bytes(description) + bytes(hint);
                    if (currentTextBytes > MAX_TEXT_BYTES) throw new Refusal("TEXT_LIMIT");
                    currentGate.inspect(text, node.isVisibleToUser());
                    currentGate.inspect(description, node.isVisibleToUser());
                    currentGate.inspect(hint, node.isVisibleToUser());
                    if ("SECRET_SURFACE".equals(currentGate.rejection())) throw new Refusal("SECRET_SURFACE");
                    int children = node.getChildCount();
                    if (children > MAX_NODES || currentCount + queue.size() + children > MAX_NODES) throw new Refusal("TREE_LIMIT");
                    for (int i = 0; i < children; i++) {
                        AccessibilityNodeInfo child = node.getChild(i);
                        if (child == null) throw new Refusal("INCOMPLETE_TREE");
                        queue.addLast(new Pending(child, pending.depth + 1));
                    }
                } finally { node.recycle(); }
            }
        } finally {
            while (!queue.isEmpty()) queue.removeFirst().node.recycle();
        }
        if (currentGate.rejection() != null) throw new Refusal("ACTIVE_REVIEW_CHANGED");
        JSONObject output = new JSONObject();
        output.put("status", "PUBLIC_REVIEW_OBSERVED");
        output.put("package", ReviewGate.VAULT);
        output.put("window_id", windowId);
        output.put("node_count", count);
        output.put("read_only", true);
        output.put("nodes", nodes);
        if (bytes(output.toString()) > MAX_OUTPUT_BYTES) throw new Refusal("OUTPUT_LIMIT");
        return output;
    }

    private static CharSequence orEmpty(CharSequence value) { return value == null ? "" : value; }
    private static boolean isPasswordInputType(int inputType) {
        int inputClass = inputType & InputType.TYPE_MASK_CLASS;
        int variation = inputType & InputType.TYPE_MASK_VARIATION;
        return (inputClass == InputType.TYPE_CLASS_TEXT &&
            (variation == InputType.TYPE_TEXT_VARIATION_PASSWORD ||
             variation == InputType.TYPE_TEXT_VARIATION_VISIBLE_PASSWORD ||
             variation == InputType.TYPE_TEXT_VARIATION_WEB_PASSWORD)) ||
            (inputClass == InputType.TYPE_CLASS_NUMBER && variation == InputType.TYPE_NUMBER_VARIATION_PASSWORD);
    }
    private static String bounded(CharSequence value) throws Refusal {
        if (value == null) return "";
        if (value.length() > MAX_FIELD_CHARS) throw new Refusal("FIELD_LIMIT");
        return value.toString();
    }
    private static int bytes(String value) { return value.getBytes(StandardCharsets.UTF_8).length; }
}
