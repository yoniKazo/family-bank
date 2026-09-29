# 🏦 הבנק המשפחתי

אפליקציית ווב (PWA) לניהול הכסף שהילדים שומרים אצל ההורים.
סטטי ב-GitHub Pages, נתונים והרשאות ב-Supabase, כניסה עם Google.

## מה יש

**הורים**
- רואים את כל הילדים והיתרות, וסה״כ בקופה
- מוסיפים הפקדה / משיכה עם סכום, תאריך והערה
- עורכים פעולה או מסמנים אותה כמבוטלת (לא נמחקת — נשארת בהיסטוריה)
- מאשרים / דוחים בקשות של הילדים, עם הערה שהילד רואה. אישור יוצר אוטומטית את הפעולה
- מוסיפים ילדים, משנים שם, מקשרים חשבון Google, מסמנים "לא פעיל"
- אזהרה (לא חסימה) כשפעולה מורידה יתרה מתחת לאפס

**ילדים**
- רואים את היתרה ואת ההיסטוריה עם ההערות
- שולחים בקשת הפקדה / משיכה עם הסבר, ויכולים לבטל בקשה שעוד לא טופלה
- לא יכולים לבצע שום פעולה כספית ולא רואים נתונים של אחים

**אבטחה** — כל ההרשאות נאכפות במסד הנתונים (Row Level Security), לא בדפדפן. גם מי שפותח את ה-DevTools עם המפתח הציבורי לא יכול לעקוף אותן. מי שמתחבר עם Google ולא מופיע ברשימה — לא רואה כלום.

## מבנה

```
docs/                 ← האתר (GitHub Pages מגיש את התיקייה הזו)
  index.html
  app.js              ← כל הלוגיקה, JS רגיל בלי build
  styles.css
  config.js           ← כתובת Supabase ומפתח ציבורי
  manifest.webmanifest, sw.js, icon.svg  ← התקנה למסך הבית
supabase/
  schema.sql          ← טבלאות, RLS, פונקציות — להריץ פעם אחת
```

## הקמה (כ-20 דקות)

### 1. Supabase
1. פותחים פרויקט חדש ב-[supabase.com](https://supabase.com) (אזור מומלץ: Frankfurt).
2. בקובץ `supabase/schema.sql`, בשורות האחרונות — מחליפים את `parent1@gmail.com` / `parent2@gmail.com` במיילים שלך ושל אשתך.
3. **SQL Editor** → מדביקים את כל הקובץ → Run. (אפשר להריץ שוב בבטחה.)
4. **Project Settings → API**: מעתיקים את ה-Project URL ואת ה-anon / publishable key.

### 2. Google OAuth
1. ב-[Google Cloud Console](https://console.cloud.google.com) → פרויקט חדש → **APIs & Services → OAuth consent screen**: סוג External, שם "הבנק המשפחתי", הרשאות בסיסיות בלבד (email, profile). בסוף — **Publish app** (עם הרשאות בסיסיות לא נדרש אימות מגוגל; בלי זה רק "Test users" יכולים להתחבר).
2. **Credentials → Create credentials → OAuth client ID** → Web application:
   - Authorized JavaScript origins: `https://<המשתמש-שלך>.github.io`
   - Authorized redirect URIs: `https://<project-ref>.supabase.co/auth/v1/callback`
3. מעתיקים Client ID ו-Client Secret.

### 3. חיבור Google ל-Supabase
1. **Authentication → Sign In / Providers → Google**: Enable, מדביקים Client ID + Secret.
2. **Authentication → URL Configuration**:
   - Site URL: `https://<המשתמש-שלך>.github.io/<שם-הריפו>/`
   - Redirect URLs: אותה כתובת, ולפיתוח מקומי גם `http://localhost:8080/`

### 4. האתר
1. ממלאים את `docs/config.js` בערכים משלב 1.4.
2. דוחפים ל-GitHub → **Settings → Pages** → Deploy from a branch → `main` / `/docs`.
3. אחרי דקה-שתיים האתר זמין ב-`https://<המשתמש-שלך>.github.io/<שם-הריפו>/`.

פיתוח מקומי: `python3 -m http.server 8080 -d docs` ולגלוש ל-`http://localhost:8080/`.

### 5. שימוש ראשון
1. נכנסים עם Google (חשבון הורה) → טאב **ניהול** → מוסיפים את הילדים. מי שיש לו חשבון Google — מכניסים את המייל.
2. בטלפון: בכרום → תפריט → **הוספה למסך הבית**. נפתח כמו אפליקציה ונשאר מחובר.

> **ילדים עם חשבון Family Link:** ייתכן שצריך לאשר בהגדרות Family Link כניסה עם Google לאפליקציות צד שלישי.

## החלטות עיצוב

- **יתרה מחושבת** מסכום הפעולות (view `balances`), לא נשמרת בנפרד — אין מצב שהיא "נסחפת".
- **ביטול רך** במקום מחיקה: פעולה מבוטלת לא נספרת ביתרה, ההורים רואים אותה מחוקה בקו, הילד לא רואה אותה.
- **מי עשה מה** — `created_by` / `updated_by` נקבעים בטריגר מתוך ה-JWT, הלקוח לא יכול לזייף.
- **אישור בקשה** הוא פונקציה אטומית אחת (`decide_request`): נועלת את הבקשה, יוצרת פעולה ומעדכנת סטטוס — בלי אישור כפול.
- **הורים** מוגדרים רק ב-SQL. מהאפליקציה אפשר לנהל רק חשבונות של ילדים.
- **תאריכים** לפי שעון ישראל.
- **שמירת התחברות** — Supabase שומר session עם refresh token, כך שלא מבקשים כניסה מחדש.

## רעיונות להמשך
- התראה להורים על בקשה חדשה (Supabase Edge Function + Web Push, או מייל)
- ריבית חודשית / "התאמת הורים" לחיסכון
- יעדי חיסכון לכל ילד
- ייצוא היסטוריה ל-CSV
