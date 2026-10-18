package com.afs.guard;

import android.app.Activity;
import android.content.Intent;
import android.content.pm.PackageManager;
import android.content.pm.ResolveInfo;
import android.graphics.Color;
import android.graphics.drawable.Drawable;
import android.os.Bundle;
import android.view.Gravity;
import android.view.View;
import android.view.ViewGroup;
import android.widget.AdapterView;
import android.widget.BaseAdapter;
import android.widget.Button;
import android.widget.CheckBox;
import android.widget.ImageView;
import android.widget.LinearLayout;
import android.widget.ListView;
import android.widget.TextView;

import java.text.Collator;
import java.util.ArrayList;
import java.util.Collections;
import java.util.Comparator;
import java.util.HashSet;
import java.util.List;
import java.util.Locale;
import java.util.Set;

/** 从已安装的可启动应用里勾选要冻结的 App。 */
public class AppPickerActivity extends Activity {

    private static final class Entry {
        String label;
        String pkg;
        Drawable icon;
        boolean checked;
    }

    private final List<Entry> items = new ArrayList<>();
    private Adapter adapter;
    private TextView hint;
    /** 已选但没安装的包（默认三件套里常常缺两个），保存时要原样留住 */
    private int hiddenKept;

    @Override
    protected void onCreate(Bundle b) {
        super.onCreate(b);

        LinearLayout root = new LinearLayout(this);
        root.setOrientation(LinearLayout.VERTICAL);
        root.setBackgroundColor(Color.parseColor("#f1f2f3"));

        hint = new TextView(this);
        hint.setPadding(dp(20), dp(16), dp(20), dp(8));
        hint.setTextSize(13);
        hint.setTextColor(Color.parseColor("#61666d"));
        root.addView(hint);

        ListView list = new ListView(this);
        list.setDividerHeight(1);
        adapter = new Adapter();
        list.setAdapter(adapter);
        list.setOnItemClickListener(new AdapterView.OnItemClickListener() {
            @Override
            public void onItemClick(AdapterView<?> p, View v, int pos, long id) {
                Entry e = items.get(pos);
                e.checked = !e.checked;
                adapter.notifyDataSetChanged();
                updateHint();
            }
        });
        root.addView(list, new LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, 0, 1f));

        Button save = new Button(this);
        save.setText("保存");
        save.setAllCaps(false);
        save.setOnClickListener(new View.OnClickListener() {
            @Override
            public void onClick(View v) {
                save();
            }
        });
        root.addView(save, new LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT));

        setContentView(root);
        load();
    }

    private void load() {
        new Thread(new Runnable() {
            @Override
            public void run() {
                final List<Entry> found = new ArrayList<>();
                try {
                    PackageManager pm = getPackageManager();
                    Intent main = new Intent(Intent.ACTION_MAIN);
                    main.addCategory(Intent.CATEGORY_LAUNCHER);
                    List<ResolveInfo> ris = pm.queryIntentActivities(main, 0);
                    Set<String> seen = new HashSet<>();
                    Set<String> picked = Targets.packages(AppPickerActivity.this);
                    for (ResolveInfo ri : ris) {
                        if (ri.activityInfo == null) {
                            continue;
                        }
                        String pkg = ri.activityInfo.packageName;
                        if (pkg == null || pkg.equals(getPackageName()) || !seen.add(pkg)) {
                            continue;
                        }
                        Entry e = new Entry();
                        e.pkg = pkg;
                        e.label = String.valueOf(ri.loadLabel(pm));
                        try {
                            e.icon = ri.loadIcon(pm);
                        } catch (Throwable ignored) {
                        }
                        e.checked = picked.contains(pkg);
                        found.add(e);
                    }
                    final Collator co = Collator.getInstance(Locale.CHINA);
                    Collections.sort(found, new Comparator<Entry>() {
                        @Override
                        public int compare(Entry a, Entry b) {
                            return co.compare(a.label, b.label);
                        }
                    });
                } catch (Throwable ignored) {
                }
                runOnUiThread(new Runnable() {
                    @Override
                    public void run() {
                        items.clear();
                        items.addAll(found);
                        Set<String> shown = new HashSet<>();
                        for (Entry e : found) {
                            shown.add(e.pkg);
                        }
                        int hidden = 0;
                        for (String p : Targets.packages(AppPickerActivity.this)) {
                            if (!shown.contains(p)) {
                                hidden++;
                            }
                        }
                        hiddenKept = hidden;
                        adapter.notifyDataSetChanged();
                        updateHint();
                    }
                });
            }
        }).start();
    }

    private void updateHint() {
        int n = 0;
        for (Entry e : items) {
            if (e.checked) {
                n++;
            }
        }
        hint.setText("已选 " + (n + hiddenKept) + " 个。屏蔽时段内这些 App 会被系统冻结，点不开。");
    }

    private void save() {
        Set<String> installable = new HashSet<>();
        for (Entry e : items) {
            installable.add(e.pkg);
        }
        Set<String> out = new HashSet<>();
        for (String p : Targets.packages(this)) {
            if (!installable.contains(p)) {
                out.add(p);
            }
        }
        for (Entry e : items) {
            if (e.checked) {
                out.add(e.pkg);
            }
        }
        Targets.setPackages(this, out);
        setResult(RESULT_OK, new Intent());
        finish();
    }

    private final class Adapter extends BaseAdapter {
        @Override
        public int getCount() {
            return items.size();
        }

        @Override
        public Object getItem(int i) {
            return items.get(i);
        }

        @Override
        public long getItemId(int i) {
            return i;
        }

        @Override
        public View getView(int pos, View convert, ViewGroup parent) {
            LinearLayout row;
            if (convert instanceof LinearLayout) {
                row = (LinearLayout) convert;
            } else {
                row = new LinearLayout(AppPickerActivity.this);
                row.setOrientation(LinearLayout.HORIZONTAL);
                row.setPadding(dp(16), dp(10), dp(16), dp(10));
                row.setBackgroundColor(Color.WHITE);

                ImageView iv = new ImageView(AppPickerActivity.this);
                iv.setId(101);
                row.addView(iv, new LinearLayout.LayoutParams(dp(40), dp(40)));

                TextView tv = new TextView(AppPickerActivity.this);
                tv.setId(102);
                tv.setTextSize(15);
                tv.setTextColor(Color.parseColor("#18191c"));
                tv.setPadding(dp(14), 0, dp(8), 0);
                tv.setGravity(Gravity.CENTER_VERTICAL);
                // 名称必须完整显示：允许折行，不省略
                tv.setSingleLine(false);
                tv.setEllipsize(null);
                tv.setMaxLines(3);
                // 名称必须完整显示：允许折行，不省略
                tv.setSingleLine(false);
                tv.setEllipsize(null);
                tv.setMaxLines(3);
                row.addView(tv, new LinearLayout.LayoutParams(0,
                        ViewGroup.LayoutParams.WRAP_CONTENT, 1f));

                CheckBox cb = new CheckBox(AppPickerActivity.this);
                cb.setId(103);
                cb.setClickable(false);
                cb.setFocusable(false);
                row.addView(cb);
            }
            Entry e = items.get(pos);
            ((TextView) row.findViewById(102)).setText(e.label);
            ((CheckBox) row.findViewById(103)).setChecked(e.checked);
            ((ImageView) row.findViewById(101)).setImageDrawable(e.icon);
            return row;
        }
    }

    private int dp(int v) {
        return (int) (v * getResources().getDisplayMetrics().density + 0.5f);
    }
}
