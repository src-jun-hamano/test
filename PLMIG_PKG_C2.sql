CREATE OR REPLACE PACKAGE PLMIG_PKG_C2 AS 

  /* 品目情報のインポート前処理 */ 
  procedure pre_hinmoku_import;
  
  /* 品目情報のインポート後処理 */
  procedure post_hinmoku_import;
  
  -- その他のインポートの事前処理
  procedure pre_others_import;
  
  /* 初期設定 */
  procedure init(
    p_company_cd in varchar2, 
    p_jigyobu_cd in varchar2, 
    p_username in varchar2, 
    p_exec_date in date
  );

  /* 会社コードの設定値を取得 */
  function get_company_cd return varchar2;

  /* 事業部コードの設定値を取得 */
  function get_jigyobu_cd return varchar2;
  
  /* 設定日の設定値を取得 */
  function get_exec_date return date;
  
  /* ユーザー名の設定値を取得 */
  function get_username return varchar2;

  /* 製品データ(共通)(FDMAM02)をワークから挿入 */
  procedure migrate_seihin;

  /*　製品(セラ１)データ(FDMAM02A)を更新 */
  procedure migrate_seihin_C2;
  
  /* 部品マスタ(TXBBM002)を更新 */
  procedure migrate_buhin;

  /* 工程マスタ(FDMAM23)を更新 */
  procedure migrate_koutei;

  /* 部品構成マスタ(FDMAM01)の更新 */
  procedure migrate_buhinkousei;
  
  /* 部品構成マスタの更新(部品-部品) */
  procedure migrate_buhinkousei_bb;
  /* 部品構成マスタの更新(製品-工程-部品) */
  procedure migrate_buhinkousei_skb;
  /* 部品構成マスタの更新(製品-工程-製品) */
  procedure migrate_buhinkousei_sks;
  /* 部品構成マスタの更新(製品-部品) */
  procedure migrate_buhinkousei_ss;
  /* 部品構成マスタの更新(製品-製品) */
  procedure migrate_buhinkousei_sb;

  /* 工程手順マスタ(FDMAM25)の更新 */
  procedure migrate_kouteitejyun;
  
  -- 工程手順構成(FDMAM26)の更新
  procedure migrate_koutei_tejyun_kousei;
  
  -- 文書マスタ(TXBBD002)の更新
  procedure migrate_doc_master;
  
  -- 管理項目マスタ(TXBBM001)更新(製品)
  procedure migrate_kanrikoumoku_seihin;
  
  -- 管理項目マスタ(TXBBM001)更新(工程)
  procedure migrate_kanrikoumoku_koutei;
  -- 管理項目マスタ(TXBBM001)更新(部品)
  procedure migrate_kanrikoumoku_buhin;

END PLMIG_PKG_C2;
/


CREATE OR REPLACE PACKAGE BODY PLMIG_PKG_C2 AS
/**
 * セラ２のデータ移行ツール
 * 
 */
  
  -- バルクインサートのサイズ
  BULK_SIZE_CONST constant PLS_INTEGER := 1000;  

  -- バルクインサート用の配列型
  type TYP_TXBBM001_ARY is table of TXBBM001%ROWTYPE index by binary_integer;

  -- バルクインサート用の配列のインデックス
  g_bulk_ix binary_integer := 0;

  -- バルクインサート用の配列
  g_kanri_rec TYP_TXBBM001_ARY;

  -- PLMIG_C2_DOC + PLMIG_C2_PNDOCのカーソル
  cursor csr_doc is 
    select 
        D.*, P.NODE_CODE AS P_NODE_CODE, P.ITEM_CODE
      from PLMIG_C2_DOC D inner join PLMIG_C2_PNDOC P 
        on D.BUNSHO_CD = P.BUNSHO_CD
    order by D.BUNSHO_CD, P.ITEM_CODE;

  -- 再帰呼び出し最大数
  MAX_RECUSIVE constant PLS_INTEGER := 99;  

  -- 再帰呼び出し最大数あふれ例外
  MAX_RECUSIVE_EXCEPTION exception;

  -- キー保存用
  g_kanri_rec_master TXBBM001%ROWTYPE;
  
  -- 実行中のプロシージャ名
  g_proc_name varchar2(40) := '';
  
  -- 移行ツールエラー
  migration_exception exception;
  
  -- エラー内容保存
  procedure handle_error(errcode in varchar2, msg in varchar2) as
  begin
    insert into PLMIG_IMP_LOG values (PLMIG_SEQ_ERROR.NEXTVAL, errcode, msg, SYSDATE, 'ERROR');
  end;

  -- ログ保存
  procedure log_write(msg in varchar2) as
  begin
    insert into PLMIG_IMP_LOG (ID,MESSAGE,TIME,KIND) values (PLMIG_SEQ_ERROR.NEXTVAL, msg, SYSDATE, 'INFO');
    commit;
  end;
  
  -- プロシージャ開始ログ
  procedure start_log(proc_name in varchar2) as 
  begin
    log_write('START  ' || proc_name );
    g_proc_name := proc_name;
  end;

  -- プロシージャ終了ログ
  procedure finish_log as 
  begin
    log_write('FINISH ' || g_proc_name );
  end;

  -- 件数ログ(※更新文の直後で呼び出し)
  procedure count_log(submsg in varchar2 := null) as 
  begin
    if submsg is null then
      log_write('COUNT(' || g_proc_name || ') => ' || SQL%ROWCOUNT);
    else
      log_write('COUNT(' || g_proc_name || '.' || submsg || ') => ' || SQL%ROWCOUNT);
    end if;
  end;
  
   --------------------------
   -- 品目情報のインポート前処理 
   --------------------------
  procedure pre_hinmoku_import AS
  BEGIN
    start_log('pre_hinmoku_import');
    -- 表を切り捨て
    execute IMMEDIATE 'truncate table PLMIG_C2_HINMOKU';
    -- 主キーを無効化
    execute IMMEDIATE 'alter table PLMIG_C2_HINMOKU disable primary key';
    finish_log;
  END pre_hinmoku_import;


   --------------------------
   -- 品目情報のインポート後処理 
   --------------------------
  procedure post_hinmoku_import AS
  BEGIN
    start_log('post_hinmoku_import');
    -- 品番の入っていない不正データを除去
    delete from PLMIG_C2_HINMOKU where ITEM_CODE is null;
    
    -- 主キーを有効化
    execute IMMEDIATE 'alter table PLMIG_C2_HINMOKU enable primary key';
    
    -- 分割用の表を切り捨て
    execute IMMEDIATE 'truncate table PLMIG_C2_BUHIN';
    execute IMMEDIATE 'truncate table PLMIG_C2_SEIHIN';
    execute IMMEDIATE 'truncate table PLMIG_C2_KOUTEI';

    -- ビューから個別の表へ
    insert into PLMIG_C2_BUHIN select * from PLMIG_V_C2_BUHIN;
    insert into PLMIG_C2_SEIHIN select * from PLMIG_V_C2_SEIHIN;
    insert into PLMIG_C2_KOUTEI select * from PLMIG_V_C2_KOUTEI;
    
    finish_log;
    
  END post_hinmoku_import;

  ----------------------------------
  -- その他のインポートの事前処理
  ----------------------------------
  procedure pre_others_import as
  begin
    start_log('pre_others_import');
    execute IMMEDIATE 'truncate table PLMIG_C2_KOUSEI';
    execute IMMEDIATE 'truncate table PLMIG_C2_DOC';
    execute IMMEDIATE 'truncate table PLMIG_C2_PNDOC';
    finish_log;
  end pre_others_import;


   --------------------------
   -- 実行環境設定  
   --------------------------
  procedure init(
    p_company_cd in varchar2,   -- 会社コード
    p_jigyobu_cd in varchar2,   -- 事業部コード
    p_username in varchar2,    -- ユーザー名
    p_exec_date in date         -- 設定日
  ) AS
  BEGIN
    MERGE INTO PLMIG_CONFIG A using (
      select 0 AS ID
      FROM DUAL
      ) B
      ON (A.ID = B.ID)
      when matched then
        update set
          A.COMPANY_CD = p_company_cd,
          A.JIGYOBU_CD = p_jigyobu_cd,
          A.USER_NAME = p_username,
          A.EXEC_DATE = p_exec_date
      when not matched then
        insert (
          A.ID, A.COMPANY_CD, A.JIGYOBU_CD, A.EXEC_DATE, A.USER_NAME
          ) values (0, p_company_cd, p_jigyobu_cd, p_exec_date, p_username);
  END init;

   --------------------------
   -- 会社コードの設定値を取得 
   --------------------------
  function get_company_cd return varchar2
  as 
    result varchar2(20);
  begin
    select company_cd into result 
        from PLMIG_CONFIG 
        where ID = 0;
    return result;
  end get_company_cd;

   --------------------------
   -- 事業部コードの設定値を取得  
   --------------------------
  function get_jigyobu_cd return varchar2 AS
    result varchar2(20);
  BEGIN
    select JIGYOBU_CD into result 
        from PLMIG_CONFIG 
        where ID = 0;
    return result;
  END get_jigyobu_cd;

   --------------------------
   -- 設定日の設定値を取得 
   --------------------------
  function get_exec_date return date AS
    result date := sysdate;
  BEGIN
    select EXEC_DATE into result 
        from PLMIG_CONFIG 
        where ID = 0;
    return result;
  END get_exec_date;

   --------------------------
   -- ユーザー名の設定値を取得  
   --------------------------
  function get_username return varchar2 AS
    result varchar2(20) := null;
  BEGIN
    select USER_NAME into result 
        from  PLMIG_CONFIG 
        where ID = 0;
    return result;
  END get_username;

   --------------------------
   --  製品データを更新
   --------------------------
  procedure migrate_seihin AS
  BEGIN
    start_log('migrate_seihin');

    -- 更新に邪魔なインデックスを一時的に無効化
    execute IMMEDIATE 'alter index FDMAM02_I02 UNUSABLE';
    --
    merge into FDMAM02 "DST" 
    using (
      SELECT * FROM PLMIG_C2_SEIHIN 
    ) "SRC"
    on (    "DST".SEIHIN_BANGO  = "SRC".ITEM_CODE 
        and "DST".COMPANYCD     = GET_COMPANY_CD 
        and "DST".JIGYOBU_CD    = GET_JIGYOBU_CD)
    when matched then
      update set
        "DST".UPDATEDPERSON             = GET_USERNAME,
        "DST".UPDATEDDT                 = GET_EXEC_DATE,
        "DST".HINMOKU_CD                = "SRC".ITEM_CODE,
        "DST".KEYNO_MCODE               = "SRC".KEYNO_MCODE,
        "DST".OLD_KEYNO                 = "SRC".OLD_KEYNO,
        "DST".HINMEI                    = "SRC".HINMEI,
        "DST".HAN_CD                    = "SRC".HAN_CD,
        "DST".KYAKUSAKI_CD              = SUBSTR("SRC".KYAKUSAKI_CD, 1, INSTR("SRC".KYAKUSAKI_CD, ':') -1),
        "DST".KYAKUSAKI_MEI_NYURYOKU    = "SRC".KYAKUSAKI_MEI_NYURYOKU,
        "DST".ZUBAN                     = "SRC".ZUBAN,
        "DST".SHAGAI_ZUBAN              = "SRC".SHAGAI_ZUBAN,
        "DST".ZAISHITSU_CD              = "SRC".ZAISHITSU_CD,
        "DST".SYOUSAI_ZAISHITSU_CD      = "SRC".SYOUSAI_ZAISHITSU_CD,
        "DST".KYAKUSAKI_PARTS_NO        = "SRC".KYAKUSAKI_PARTS_NO,
        "DST".YUKO_FLG                  = "SRC".YUKO_FLG,
        "DST".TEISHI_KAISHI             = "SRC".TEISHI_KAISHI,
        "DST".GYOMU_HANSU               = "SRC".GYOMU_HANSU
    when not matched then
      insert (
        "DST".COMPANYCD,
        "DST".REGISTEREDPERSON,
        "DST".REGISTEREDDT,
        "DST".UPDATEDPERSON,
        "DST".UPDATEDDT,
        "DST".JIGYOBU_CD,
        "DST".SEIHIN_BANGO,
        "DST".HINMOKU_CD,
        "DST".KEYNO_MCODE,
        "DST".OLD_KEYNO,
        "DST".HINMEI,
        "DST".HAN_CD,
        "DST".KYAKUSAKI_CD,
        "DST".KYAKUSAKI_MEI_NYURYOKU,
        "DST".ZUBAN,
        "DST".SHAGAI_ZUBAN,
        "DST".ZAISHITSU_CD,
        "DST".SYOUSAI_ZAISHITSU_CD,
        "DST".KYAKUSAKI_PARTS_NO,
        "DST".YUKO_FLG,
        "DST".TEISHI_KAISHI,
        "DST".GYOMU_HANSU
      ) values (
        GET_COMPANY_CD,
        GET_USERNAME,
        GET_EXEC_DATE,
        GET_USERNAME,
        GET_EXEC_DATE,
        GET_JIGYOBU_CD,
        "SRC".ITEM_CODE,
        "SRC".ITEM_CODE,
        "SRC".KEYNO_MCODE,
        "SRC".OLD_KEYNO,
        "SRC".HINMEI,
        "SRC".HAN_CD,
        SUBSTR("SRC".KYAKUSAKI_CD, 1, INSTR("SRC".KYAKUSAKI_CD, ':') -1),
        "SRC".KYAKUSAKI_MEI_NYURYOKU,
        "SRC".ZUBAN,
        "SRC".SHAGAI_ZUBAN,
        "SRC".ZAISHITSU_CD,
        "SRC".SYOUSAI_ZAISHITSU_CD,
        "SRC".KYAKUSAKI_PARTS_NO,
        "SRC".YUKO_FLG,
        "SRC".TEISHI_KAISHI,
        "SRC".GYOMU_HANSU
      );
    count_log;
    commit;
    -- 無効化していたインデックスを再構築
    execute IMMEDIATE 'alter index FDMAM02_I02 REBUILD';
    finish_log;
  END migrate_seihin;

   --------------------------
   -- 製品(セラ２)データを更新 
   --------------------------
  procedure migrate_seihin_C2 AS
  BEGIN
    start_log('migrate_seihin_C2');
    -- 更新に邪魔なインデックスを一時的に無効化
    execute IMMEDIATE 'alter index FDMAM02B_I02 UNUSABLE';
    --
    merge into FDMAM02B "DST" 
    using (
      SELECT * FROM PLMIG_C2_SEIHIN 
    ) "SRC"
    on (    "DST".SEIHIN_BANGO  = "SRC".ITEM_CODE 
        and "DST".COMPANYCD     = GET_COMPANY_CD 
        and "DST".JIGYOBU_CD    = GET_JIGYOBU_CD)
    when matched then
      update set
        "DST".UPDATEDPERSON                 = GET_USERNAME,
        "DST".UPDATEDDT                     = GET_EXEC_DATE,
        "DST".HINMOKU_CD                    =   "SRC".ITEM_CODE,
        "DST".KYOTSU_HIN                    =   "SRC".KYOTSU_HIN,
        "DST".KANRI_BANGO                   =   "SRC".KANRI_BANGO,
        "DST".BIKO                          =   "SRC".BIKO,
        "DST".KC_PARTS_NO                   =   "SRC".KC_PARTS_NO,
        "DST".TANI_HENKAN_KBN               =   "SRC".TANI_HENKAN_KBN,
        "DST".TANI_HENKAN                   =   "SRC".TANI_HENKAN,
        "DST".SET_FLG                       =   "SRC".SET_FLG,
        "DST".TYPE                          =   "SRC".TYPE,
        "DST".JYOTAI                        =   "SRC".JYOTAI,
        "DST".KYOTSU_SHIYO_1                =   "SRC".KYOTSU_SHIYO_1,
        "DST".KYOTSU_SHIYO_2                =   "SRC".KYOTSU_SHIYO_2,
        "DST".KYOTSU_SHIYO_3                =   "SRC".KYOTSU_SHIYO_3,
        "DST".SPEC1                         =   "SRC".SPEC1,
        "DST".SPEC2                         =   "SRC".SPEC2,
        "DST".SPEC3                         =   "SRC".SPEC3,
        "DST".HIKIOTOSHI_KOTEI              =   "SRC".HIKIOTOSHI_KOTEI,
        "DST".GENZANKOKU                    =   "SRC".GENZANKOKU,
        "DST".KOTEI_NASHI_HIN               =   "SRC".KOTEI_NASHI_HIN,
        "DST".BUNRUI                        =   "SRC".BUNRUI,
        "DST".KAMOKU                        =   "SRC".KAMOKU,
        "DST".KANAGATA_UMU                  =   "SRC".KANAGATA_UMU,
        "DST".GAISUN_TATE                   =   "SRC".GAISUN_TATE,
        "DST".GAISUN_YOKO                   =   "SRC".GAISUN_YOKO,
        "DST".GAISUN_TAKASA                 =   "SRC".GAISUN_TAKASA,
        "DST".GAIKEI                        =   "SRC".GAIKEI,
        "DST".NAIKEI                        =   "SRC".NAIKEI,
        "DST".KEIJYO                        =   "SRC".KEIJYO,
        "DST".ZAISHITSU_BUNRUI              =   "SRC".ZAISHITSU_BUNRUI,
        "DST".ZAISHITSU_GAIKAN              =   "SRC".ZAISHITSU_GAIKAN,
        "DST".META_YUYAKU_UMU               =   "SRC".META_YUYAKU_UMU,
        "DST".SESSAKU_KAKO_UMU              =   "SRC".SESSAKU_KAKO_UMU,
        "DST".KENSAKU_KAKO_UMU              =   "SRC".KENSAKU_KAKO_UMU,
        "DST".ATSUMI_KENMA_KAKO_UMU         =   "SRC".ATSUMI_KENMA_KAKO_UMU,
        "DST".CENTERLESS_KENMA_KAKO_UMU     =   "SRC".CENTERLESS_KENMA_KAKO_UMU,
        "DST".KANAGATA_KOZO_UE_PUNCH        =   "SRC".KANAGATA_KOZO_UE_PUNCH,
        "DST".KANAGATA_KOZO_SHITA_PUNCH     =   "SRC".KANAGATA_KOZO_SHITA_PUNCH,
        "DST".KANAGATA_KOZO_USU             =   "SRC".KANAGATA_KOZO_USU,
        "DST".KANAGATA_KOZO_CORE            =   "SRC".KANAGATA_KOZO_CORE,
        "DST".PRESS_KISHU                   =   "SRC".PRESS_KISHU,
        "DST".TON_SU                        =   "SRC".TON_SU,
        "DST".HINSHU_YOTO                   =   "SRC".HINSHU_YOTO,
        "DST".KANAGATA_BANGO                =   "SRC".KANAGATA_BANGO,
        "DST".KOKYAKU_AREA                  =   "SRC".KOKYAKU_AREA,
        "DST".YUDENTAI_OLD_KEYNO            =   "SRC".YUDENTAI_OLD_KEYNO,
        "DST".SURYO                         =   "SRC".SURYO,
        "DST".KAKAKU                        =   "SRC".KAKAKU,
        "DST".GIJUTU_YOSO                   =   "SRC".GIJUTSU_YOSO,
        "DST".FUGUAI_SHURUI                 =   "SRC".FUGUAI_SHURUI,
        "DST".JIGU_TOOL_DAI_UMU             =   "SRC".JIGU_TOOL_DAI_UMU,
        "DST".SOKUTEI_PLAN                  =   "SRC".SOKUTEI_PLAN,
        "DST".SUNPOU_TIGHT                  =   "SRC".SUNPOU_TIGHT,
        "DST".KONPO_PLAN                    =   "SRC".KONPO_PLAN,
        "DST".MEKKI_UMU                     =   "SRC".MEKKI_UMU,
        "DST".KATTA_UMU                     =   "SRC".KATTA_UMU,
        "DST".THROUGH_HOLE_DIAMETER         =   "SRC".THROUGH_HOLE_DIAMETER,
        "DST".MITSUMORI_DAICHO_BANGO        =   "SRC".MITSUMORI_DAICHO_BANGO,
        "DST".MITSUMORI_DAICHO_HANSU        =   "SRC".MITSUMORI_DAICHO_HANSU,
        "DST".MITSUMORIJI_KYAKUSAKI_MEI     =   "SRC".MITSUMORIJI_KYAKUSAKI_MEI,
        "DST".ZANTEI_TANKA                  =   "SRC".ZANTEI_TANKA,
        "DST".CHK_COMMENT_1                 =   "SRC".CHK_COMMENT_1,
        "DST".CHK_COMMENT_2                 =   "SRC".CHK_COMMENT_2,
        "DST".CHK_COMMENT_3                 =   "SRC".CHK_COMMENT_3,
        "DST".COMMENT_1                     =   "SRC".COMMENT_1,
        "DST".COMMENT_2                     =   "SRC".COMMENT_2,
        "DST".COMMENT_3                     =   "SRC".COMMENT_3
        
    when not matched then
      insert (
        "DST".COMPANYCD,
        "DST".REGISTEREDPERSON,
        "DST".REGISTEREDDT,
        "DST".UPDATEDPERSON,
        "DST".UPDATEDDT,
        "DST".JIGYOBU_CD,
        "DST".SEIHIN_BANGO,
        "DST".HINMOKU_CD,
        "DST".KYOTSU_HIN,
        "DST".KANRI_BANGO,
        "DST".BIKO,
        "DST".KC_PARTS_NO,
        "DST".TANI_HENKAN_KBN,
        "DST".TANI_HENKAN,
        "DST".SET_FLG,
        "DST".TYPE,
        "DST".JYOTAI,
        "DST".KYOTSU_SHIYO_1,
        "DST".KYOTSU_SHIYO_2,
        "DST".KYOTSU_SHIYO_3,
        "DST".SPEC1,
        "DST".SPEC2,
        "DST".SPEC3,
        "DST".HIKIOTOSHI_KOTEI,
        "DST".GENZANKOKU,
        "DST".KOTEI_NASHI_HIN,
        "DST".BUNRUI,
        "DST".KAMOKU,
        "DST".KANAGATA_UMU,
        "DST".GAISUN_TATE,
        "DST".GAISUN_YOKO,
        "DST".GAISUN_TAKASA,
        "DST".GAIKEI,
        "DST".NAIKEI,
        "DST".KEIJYO,
        "DST".ZAISHITSU_BUNRUI,
        "DST".ZAISHITSU_GAIKAN,
        "DST".META_YUYAKU_UMU,
        "DST".SESSAKU_KAKO_UMU,
        "DST".KENSAKU_KAKO_UMU,
        "DST".ATSUMI_KENMA_KAKO_UMU,
        "DST".CENTERLESS_KENMA_KAKO_UMU,
        "DST".KANAGATA_KOZO_UE_PUNCH,
        "DST".KANAGATA_KOZO_SHITA_PUNCH,
        "DST".KANAGATA_KOZO_USU,
        "DST".KANAGATA_KOZO_CORE,
        "DST".PRESS_KISHU,
        "DST".TON_SU,
        "DST".HINSHU_YOTO,
        "DST".KANAGATA_BANGO,
        "DST".KOKYAKU_AREA,
        "DST".YUDENTAI_OLD_KEYNO,
        "DST".SURYO,
        "DST".KAKAKU,
        "DST".GIJUTU_YOSO,
        "DST".FUGUAI_SHURUI,
        "DST".JIGU_TOOL_DAI_UMU,
        "DST".SOKUTEI_PLAN,
        "DST".SUNPOU_TIGHT,
        "DST".KONPO_PLAN,
        "DST".MEKKI_UMU,
        "DST".KATTA_UMU,
        "DST".THROUGH_HOLE_DIAMETER,
        "DST".MITSUMORI_DAICHO_BANGO,
        "DST".MITSUMORI_DAICHO_HANSU,
        "DST".MITSUMORIJI_KYAKUSAKI_MEI,
        "DST".ZANTEI_TANKA,
        "DST".CHK_COMMENT_1,
        "DST".CHK_COMMENT_2,
        "DST".CHK_COMMENT_3,
        "DST".COMMENT_1,
        "DST".COMMENT_2,
        "DST".COMMENT_3
    ) values (
        GET_COMPANY_CD,
        GET_USERNAME,
        GET_EXEC_DATE,
        GET_USERNAME,
        GET_EXEC_DATE,
        GET_JIGYOBU_CD,
        "SRC".ITEM_CODE,
        "SRC".ITEM_CODE,
        "SRC".KYOTSU_HIN,
        "SRC".KANRI_BANGO,
        "SRC".BIKO,
        "SRC".KC_PARTS_NO,
        "SRC".TANI_HENKAN_KBN,
        "SRC".TANI_HENKAN,
        "SRC".SET_FLG,
        "SRC".TYPE,
        "SRC".JYOTAI,
        "SRC".KYOTSU_SHIYO_1,
        "SRC".KYOTSU_SHIYO_2,
        "SRC".KYOTSU_SHIYO_3,
        "SRC".SPEC1,
        "SRC".SPEC2,
        "SRC".SPEC3,
        "SRC".HIKIOTOSHI_KOTEI,
        "SRC".GENZANKOKU,
        "SRC".KOTEI_NASHI_HIN,
        "SRC".BUNRUI,
        "SRC".KAMOKU,
        "SRC".KANAGATA_UMU,
        "SRC".GAISUN_TATE,
        "SRC".GAISUN_YOKO,
        "SRC".GAISUN_TAKASA,
        "SRC".GAIKEI,
        "SRC".NAIKEI,
        "SRC".KEIJYO,
        "SRC".ZAISHITSU_BUNRUI,
        "SRC".ZAISHITSU_GAIKAN,
        "SRC".META_YUYAKU_UMU,
        "SRC".SESSAKU_KAKO_UMU,
        "SRC".KENSAKU_KAKO_UMU,
        "SRC".ATSUMI_KENMA_KAKO_UMU,
        "SRC".CENTERLESS_KENMA_KAKO_UMU,
        "SRC".KANAGATA_KOZO_UE_PUNCH,
        "SRC".KANAGATA_KOZO_SHITA_PUNCH,
        "SRC".KANAGATA_KOZO_USU,
        "SRC".KANAGATA_KOZO_CORE,
        "SRC".PRESS_KISHU,
        "SRC".TON_SU,
        "SRC".HINSHU_YOTO,
        "SRC".KANAGATA_BANGO,
        "SRC".KOKYAKU_AREA,
        "SRC".YUDENTAI_OLD_KEYNO,
        "SRC".SURYO,
        "SRC".KAKAKU,
        "SRC".GIJUTSU_YOSO,
        "SRC".FUGUAI_SHURUI,
        "SRC".JIGU_TOOL_DAI_UMU,
        "SRC".SOKUTEI_PLAN,
        "SRC".SUNPOU_TIGHT,
        "SRC".KONPO_PLAN,
        "SRC".MEKKI_UMU,
        "SRC".KATTA_UMU,
        "SRC".THROUGH_HOLE_DIAMETER,
        "SRC".MITSUMORI_DAICHO_BANGO,
        "SRC".MITSUMORI_DAICHO_HANSU,
        "SRC".MITSUMORIJI_KYAKUSAKI_MEI,
        "SRC".ZANTEI_TANKA,
        "SRC".CHK_COMMENT_1,
        "SRC".CHK_COMMENT_2,
        "SRC".CHK_COMMENT_3,
        "SRC".COMMENT_1,
        "SRC".COMMENT_2,
        "SRC".COMMENT_3
      );

    count_log;
    commit;
    -- 無効化していたインデックスを再構築
    execute IMMEDIATE 'alter index FDMAM02B_I02 REBUILD';
    finish_log;
  END migrate_seihin_C2;

   --------------------------
   -- 部品マスタを更新
   --------------------------
  procedure migrate_buhin as
  begin
    start_log('migrate_buhin');
    merge into TXBBM002 D 
    using (
      SELECT * FROM PLMIG_C2_BUHIN 
    ) S
    on (    D.BUHIN_BANGO  = S.ITEM_CODE 
        and D.COMPANYCD     = GET_COMPANY_CD 
        and D.JIGYOBU_CD    = GET_JIGYOBU_CD)
    when matched then
      update set
        D.UPDATEDPERSON         =   GET_USERNAME,
        D.UPDATEDDT             =   GET_EXEC_DATE,
        D.BUHIN_CD              =   S.BUHIN_CD,
        D.BUHIN_MEI             =   S.BUHIN_MEI,
        D.BUHIN_ZUBAN           =   S.BUHIN_ZUBAN,
        D.ZAISHITSU_CD          =   S.ZAISHITSU_CD_BUHIN,
        D.SHIIRESAKI_CD         =   S.SHIIRESAKI_CD_BUHIN,
        D.SHIIRESAKI_MEI        =   S.SHIIRESAKI_MEI_BUHIN,
        D.KINGAKU               =   S.KINGAKU_BUHIN,
        D.BUZAI_KBN             =   S.BUZAI_KBN,
        D.BIKO                  =   S.BIKO_BUHIN,
        D.GYOMU_HANSU           =   S.GYOMU_HANSU
    when not matched then
      insert (
        D.COMPANYCD,
        D.REGISTEREDPERSON,
        D.REGISTEREDDT,
        D.UPDATEDPERSON,
        D.UPDATEDDT,
        D.JIGYOBU_CD,
        D.BUHIN_BANGO,
        D.BUHIN_CD,
        D.BUHIN_MEI,
        D.BUHIN_ZUBAN,
        D.ZAISHITSU_CD,
        D.SHIIRESAKI_CD,
        D.SHIIRESAKI_MEI,
        D.KINGAKU,
        D.BUZAI_KBN,
        D.BIKO,
        D.GYOMU_HANSU
      ) values (
        GET_COMPANY_CD,
        GET_USERNAME,
        GET_EXEC_DATE,
        GET_USERNAME,
        GET_EXEC_DATE,
        GET_JIGYOBU_CD,
        S.ITEM_CODE,
        S.BUHIN_CD,
        S.BUHIN_MEI,
        S.BUHIN_ZUBAN,
        S.ZAISHITSU_CD_BUHIN,
        S.SHIIRESAKI_CD_BUHIN,
        S.SHIIRESAKI_MEI_BUHIN,
        S.KINGAKU_BUHIN,
        S.BUZAI_KBN,
        S.BIKO_BUHIN,
        S.GYOMU_HANSU
      );
    count_log;
    commit;
    finish_log;
  end migrate_buhin;

   --------------------------
   -- 工程マスタを更新 
   --------------------------
  procedure migrate_koutei as
  begin
    start_log('migrate_koutei');
    merge into FDMAM23 D 
    using (
        select   KOTEI_CD, KOTEI_MEI 
        from PLMIG_C2_KOUTEI 
        group by KOTEI_CD, KOTEI_MEI 
    ) S
    on (    D.KOTEI_CD  = S.KOTEI_CD 
        and D.COMPANYCD     = GET_COMPANY_CD 
        and D.JIGYOBU_CD    = GET_JIGYOBU_CD)
    when matched then
      update set
        D.UPDATEDPERSON         =   GET_USERNAME,
        D.UPDATEDDT             =   GET_EXEC_DATE,
        D.KOTEI_MEI             =   S.KOTEI_MEI
    when not matched then
      insert (
        D.COMPANYCD,
        D.REGISTEREDPERSON,
        D.REGISTEREDDT,
        D.UPDATEDPERSON,
        D.UPDATEDDT,
        D.JIGYOBU_CD,
        D.KOTEI_CD,
        D.KOTEI_MEI
      ) values (
        GET_COMPANY_CD,
        GET_USERNAME,
        GET_EXEC_DATE,
        GET_USERNAME,
        GET_EXEC_DATE,
        GET_JIGYOBU_CD,
        S.KOTEI_CD,
        S.KOTEI_MEI
      );
    count_log;
    commit;
    finish_log;
  end migrate_koutei;

   --------------------------
   -- 部品構成マスタの更新 
   --------------------------
  procedure migrate_buhinkousei AS
  begin
    start_log('migrate_buhinkousei');
    execute IMMEDIATE 'alter index FDMAM01_I02 UNUSABLE';
    migrate_buhinkousei_bb;
    migrate_buhinkousei_skb;
    migrate_buhinkousei_sks;
    migrate_buhinkousei_ss;
    migrate_buhinkousei_sb;
    execute IMMEDIATE 'alter index FDMAM01_I02 REBUILD';
    finish_log;
  end migrate_buhinkousei;
  
   --------------------------
   -- 部品構成マスタの更新(部品-部品) 
   --------------------------
  procedure migrate_buhinkousei_bb as
  begin
    merge into FDMAM01 DST 
    using  PLMIG_V_C2_BUHINKOUSEI_BB SRC
    on (    DST.OYASEIHIN_BANGO = SRC.OYA_HINBAN
        and DST.KOSEIHIN_BANGO = SRC.KO_HINBAN
        and DST.COMPANYCD     = GET_COMPANY_CD 
        and DST.JIGYOBU_CD    = GET_JIGYOBU_CD)

    when matched then
      update set
        DST.UPDATEDPERSON       = GET_USERNAME,
        DST.UPDATEDDT           = GET_EXEC_DATE,
        DST.OYAHINMOKU_CD   = SRC.OYA_BUHIN_CD,
        DST.OYAIN_SU        = 1,
        DST.KOHINMOKU_CD    = SRC.KO_BUHIN_CD,
        DST.KOIN_SU         = SRC.KOIN_SU,
        DST.SORT_NO         = SRC.SORT_ORDER,
        DST.JOI_KOTEI       = null,
        DST.TORI_SU         = SRC.TORI_SU
        
    when not matched then
      insert (
        DST.COMPANYCD,
        DST.REGISTEREDPERSON,
        DST.REGISTEREDDT,
        DST.UPDATEDPERSON,
        DST.UPDATEDDT,
        DST.JIGYOBU_CD,
        DST.OYASEIHIN_BANGO,
        DST.OYAHINMOKU_CD,
        DST.OYAIN_SU,
        DST.KOSEIHIN_BANGO,
        DST.KOHINMOKU_CD,
        DST.KOIN_SU,
        DST.SORT_NO,
        DST.JOI_KOTEI,
        DST.TORI_SU
      ) values (
        GET_COMPANY_CD,
        GET_USERNAME,
        GET_EXEC_DATE,
        GET_USERNAME,
        GET_EXEC_DATE,
        GET_JIGYOBU_CD,
        SRC.OYA_HINBAN,
        SRC.OYA_BUHIN_CD,
        1,
        SRC.KO_HINBAN,
        SRC.KO_BUHIN_CD,
        SRC.KOIN_SU,
        SRC.SORT_ORDER,
        null,
        SRC.TORI_SU
      );
    count_log('部品-部品');
    commit;
  end migrate_buhinkousei_bb;
  
   --------------------------
   -- 部品構成マスタの更新(製品-工程-部品) 
   --------------------------
  procedure migrate_buhinkousei_skb as
  begin
    merge into FDMAM01 DST 
    using  PLMIG_V_C2_BUHINKOUSEI_SKB SRC
    on (    DST.OYASEIHIN_BANGO = SRC.OYA_HINBAN
        and DST.KOSEIHIN_BANGO = SRC.KO_HINBAN
        and DST.COMPANYCD     = GET_COMPANY_CD 
        and DST.JIGYOBU_CD    = GET_JIGYOBU_CD)

    when matched then
      update set
        DST.UPDATEDPERSON       = GET_USERNAME,
        DST.UPDATEDDT           = GET_EXEC_DATE,
        DST.OYAHINMOKU_CD   = SRC.OYA_HINBAN,
        DST.OYAIN_SU        = 1,
        DST.KOHINMOKU_CD    = SRC.BUHIN_CD,
        DST.KOIN_SU         = SRC.KOIN_SU,
        DST.SORT_NO         = SRC.SORT_ORDER,
        DST.JOI_KOTEI       = SRC.KOTEI_CD,
        DST.TORI_SU         = SRC.TORI_SU
        
    when not matched then
      insert (
        DST.COMPANYCD,
        DST.REGISTEREDPERSON,
        DST.REGISTEREDDT,
        DST.UPDATEDPERSON,
        DST.UPDATEDDT,
        DST.JIGYOBU_CD,
        DST.OYASEIHIN_BANGO,
        DST.OYAHINMOKU_CD,
        DST.OYAIN_SU,
        DST.KOSEIHIN_BANGO,
        DST.KOHINMOKU_CD,
        DST.KOIN_SU,
        DST.SORT_NO,
        DST.JOI_KOTEI,
        DST.TORI_SU
      ) values (
        GET_COMPANY_CD,
        GET_USERNAME,
        GET_EXEC_DATE,
        GET_USERNAME,
        GET_EXEC_DATE,
        GET_JIGYOBU_CD,
        SRC.OYA_HINBAN,
        SRC.OYA_HINBAN,
        1,
        SRC.KO_HINBAN,
        SRC.BUHIN_CD,
        SRC.KOIN_SU,
        SRC.SORT_ORDER,
        SRC.KOTEI_CD,
        SRC.TORI_SU
      );
    count_log('製品-工程-部品');
    commit;
  end migrate_buhinkousei_skb;

   --------------------------
   -- 部品構成マスタの更新(製品-工程-製品) 
   --------------------------
  procedure migrate_buhinkousei_sks as
  begin
    merge into FDMAM01 DST 
    using  PLMIG_V_C2_BUHINKOUSEI_SKS SRC
    on (    DST.OYASEIHIN_BANGO = SRC.OYA_HINBAN
        and DST.KOSEIHIN_BANGO = SRC.KO_HINBAN
        and DST.COMPANYCD     = GET_COMPANY_CD 
        and DST.JIGYOBU_CD    = GET_JIGYOBU_CD)

    when matched then
      update set
        DST.UPDATEDPERSON       = GET_USERNAME,
        DST.UPDATEDDT           = GET_EXEC_DATE,
        DST.OYAHINMOKU_CD   = SRC.OYA_HINBAN,
        DST.OYAIN_SU        = 1,
        DST.KOHINMOKU_CD    = SRC.KO_HINBAN,
        DST.KOIN_SU         = SRC.KOIN_SU,
        DST.SORT_NO         = SRC.SORT_ORDER,
        DST.JOI_KOTEI       = SRC.KOTEI_CD,
        DST.TORI_SU         = SRC.TORI_SU
        
    when not matched then
      insert (
        DST.COMPANYCD,
        DST.REGISTEREDPERSON,
        DST.REGISTEREDDT,
        DST.UPDATEDPERSON,
        DST.UPDATEDDT,
        DST.JIGYOBU_CD,
        DST.OYASEIHIN_BANGO,
        DST.OYAHINMOKU_CD,
        DST.OYAIN_SU,
        DST.KOSEIHIN_BANGO,
        DST.KOHINMOKU_CD,
        DST.KOIN_SU,
        DST.SORT_NO,
        DST.JOI_KOTEI,
        DST.TORI_SU
      ) values (
        GET_COMPANY_CD,
        GET_USERNAME,
        GET_EXEC_DATE,
        GET_USERNAME,
        GET_EXEC_DATE,
        GET_JIGYOBU_CD,
        SRC.OYA_HINBAN,
        SRC.OYA_HINBAN,
        1,
        SRC.KO_HINBAN,
        SRC.KO_HINBAN,
        SRC.KOIN_SU,
        SRC.SORT_ORDER,
        SRC.KOTEI_CD,
        SRC.TORI_SU
      );
    count_log('製品-工程-製品');
    commit;
  end migrate_buhinkousei_sks;

   --------------------------
   -- 部品構成マスタの更新(製品-製品) 
   --------------------------
  procedure migrate_buhinkousei_ss as
  begin
    merge into FDMAM01 DST 
    using  PLMIG_V_C2_BUHINKOUSEI_SS SRC
    on (    DST.OYASEIHIN_BANGO = SRC.OYA_HINBAN
        and DST.KOSEIHIN_BANGO = SRC.KO_HINBAN
        and DST.COMPANYCD     = GET_COMPANY_CD 
        and DST.JIGYOBU_CD    = GET_JIGYOBU_CD)

    when matched then
      update set
        DST.UPDATEDPERSON       = GET_USERNAME,
        DST.UPDATEDDT           = GET_EXEC_DATE,
        DST.OYAHINMOKU_CD   = SRC.OYA_HINBAN,
        DST.OYAIN_SU        = 1,
        DST.KOHINMOKU_CD    = SRC.KO_HINBAN,
        DST.KOIN_SU         = SRC.KOIN_SU,
        DST.SORT_NO         = SRC.SORT_ORDER,
        DST.JOI_KOTEI       = null,
        DST.TORI_SU         = SRC.TORI_SU
        
    when not matched then
      insert (
        DST.COMPANYCD,
        DST.REGISTEREDPERSON,
        DST.REGISTEREDDT,
        DST.UPDATEDPERSON,
        DST.UPDATEDDT,
        DST.JIGYOBU_CD,
        DST.OYASEIHIN_BANGO,
        DST.OYAHINMOKU_CD,
        DST.OYAIN_SU,
        DST.KOSEIHIN_BANGO,
        DST.KOHINMOKU_CD,
        DST.KOIN_SU,
        DST.SORT_NO,
        DST.JOI_KOTEI,
        DST.TORI_SU
      ) values (
        GET_COMPANY_CD,
        GET_USERNAME,
        GET_EXEC_DATE,
        GET_USERNAME,
        GET_EXEC_DATE,
        GET_JIGYOBU_CD,
        SRC.OYA_HINBAN,
        SRC.OYA_HINBAN,
        1,
        SRC.KO_HINBAN,
        SRC.KO_HINBAN,
        SRC.KOIN_SU,
        SRC.SORT_ORDER,
        null,
        SRC.TORI_SU
      );
    count_log('製品-製品');
    commit;
  end migrate_buhinkousei_ss;

   --------------------------
   -- 部品構成マスタの更新(製品-部品) 
   --------------------------
  procedure migrate_buhinkousei_sb as
  begin
    merge into FDMAM01 DST 
    using  PLMIG_V_C2_BUHINKOUSEI_SB SRC
    on (    DST.OYASEIHIN_BANGO = SRC.OYA_HINBAN
        and DST.KOSEIHIN_BANGO = SRC.KO_HINBAN
        and DST.COMPANYCD     = GET_COMPANY_CD 
        and DST.JIGYOBU_CD    = GET_JIGYOBU_CD)

    when matched then
      update set
        DST.UPDATEDPERSON       = GET_USERNAME,
        DST.UPDATEDDT           = GET_EXEC_DATE,
        DST.OYAHINMOKU_CD   = SRC.OYA_M_CODE,
        DST.OYAIN_SU        = 1,
        DST.KOHINMOKU_CD    = SRC.KO_BUHIN_CD,
        DST.KOIN_SU         = SRC.KOIN_SU,
        DST.SORT_NO         = SRC.SORT_ORDER,
        DST.JOI_KOTEI       = null,
        DST.TORI_SU         = SRC.TORI_SU
        
    when not matched then
      insert (
        DST.COMPANYCD,
        DST.REGISTEREDPERSON,
        DST.REGISTEREDDT,
        DST.UPDATEDPERSON,
        DST.UPDATEDDT,
        DST.JIGYOBU_CD,
        DST.OYASEIHIN_BANGO,
        DST.OYAHINMOKU_CD,
        DST.OYAIN_SU,
        DST.KOSEIHIN_BANGO,
        DST.KOHINMOKU_CD,
        DST.KOIN_SU,
        DST.SORT_NO,
        DST.JOI_KOTEI,
        DST.TORI_SU
      ) values (
        GET_COMPANY_CD,
        GET_USERNAME,
        GET_EXEC_DATE,
        GET_USERNAME,
        GET_EXEC_DATE,
        GET_JIGYOBU_CD,
        SRC.OYA_HINBAN,
        SRC.OYA_M_CODE,
        1,
        SRC.KO_HINBAN,
        SRC.KO_BUHIN_CD,
        SRC.KOIN_SU,
        SRC.SORT_ORDER,
        null,
        SRC.TORI_SU
      );
    count_log('製品-部品');
    commit;
  end migrate_buhinkousei_sb;

   --------------------------
   -- 工程手順マスタの更新 
   --------------------------
  procedure migrate_kouteitejyun as
  begin
    start_log('migrate_kouteitejyun');
    -- 更新に邪魔なインデックスを一時的に無効化
    execute IMMEDIATE 'alter index FDMAM25_I02 UNUSABLE';
    --
    merge into FDMAM25 D 
    using (
      SELECT * FROM PLMIG_C2_SEIHIN 
    ) S
    on (    D.SEIHIN_BANGO  = S.ITEM_CODE 
        and D.COMPANYCD     = GET_COMPANY_CD 
        and D.JIGYOBU_CD    = GET_JIGYOBU_CD)
    when matched then
      update set
        D.UPDATEDPERSON      = GET_USERNAME,
        D.UPDATEDDT          = GET_EXEC_DATE,
        D.KOTEI_TEJUN_CD     = S.ITEM_CODE,
        D.KOTEI_TEJUN_MEI    = SUBSTRB(S.HINMEI, 1, 120)
        
    when not matched then
      insert (
        D.COMPANYCD,
        D.REGISTEREDPERSON,
        D.REGISTEREDDT,
        D.UPDATEDPERSON,
        D.UPDATEDDT,
        D.JIGYOBU_CD,
        D.SEIHIN_BANGO,
        D.KOTEI_TEJUN_CD,
        D.KOUHOU_BANGO,
        D.KOTEI_TEJUN_REV,
        D.KAKOU_TEJUN_REV,
        D.KOTEI_TEJUN_MEI,
        D.KAITEI_KBN,
        D.SHOCHISHIJI_NO
      ) values (
        GET_COMPANY_CD,
        GET_USERNAME,
        GET_EXEC_DATE,
        GET_USERNAME,
        GET_EXEC_DATE,
        GET_JIGYOBU_CD,
        S.ITEM_CODE,
        S.ITEM_CODE,
        '0',
        '001',
        '001',
        SUBSTRB(S.HINMEI, 1, 120),
        '0',
        '0000'
      );
    count_log;
    commit;
    -- 無効化していたインデックスを再構築
    execute IMMEDIATE 'alter index FDMAM25_I02 REBUILD';
    finish_log;

  exception
    when others then
      rollback;
      handle_error(SQLCODE, SQLERRM);
      raise migration_exception;
  end migrate_kouteitejyun;

  -----------------------------
  -- 工程手順構成の更新
  -----------------------------
  procedure migrate_koutei_tejyun_kousei as 
  begin
    start_log('migrate_koutei_tejyun_kousei');
    -- 更新に邪魔なインデックスを一時的に無効化
    execute IMMEDIATE 'alter index FDMAM26_I02 UNUSABLE';
    --
    merge into FDMAM26 DST 
    using PLMIG_V_C2_TEJUNKOUSEI SRC
    on (    DST.SEIHIN_BANGO  = SRC.SEIHIN_BANGO
        and DST.KOTEI_BANGO   = SRC.KOTEI_BANGO
        and DST.COMPANYCD     = GET_COMPANY_CD 
        and DST.JIGYOBU_CD    = GET_JIGYOBU_CD)
    when matched then
      update set
        DST.UPDATEDPERSON           = GET_USERNAME,
        DST.UPDATEDDT               = GET_EXEC_DATE,
        DST.KOTEI_TEJUN_CD         = SRC.SEIHIN_BANGO,
        DST.KOTEI_CD               = SRC.KOTEI_CD,
        DST.KOTEI_NO               = SRC.KOTEI_JUNBAN,
        DST.JISSEKI_NYURYOKU_UMU   = SRC.HYOJUN_JISSEKI_NYURYOKU_UMU,
        DST.JUNFUDO_GRP            = SRC.KOTEI_GRP,
        DST.SHIYO1                 = SRC.SHIYO1,
        DST.SHIYO2                 = SRC.SHIYO2,
        DST.SHIYO3                 = SRC.SHIYO3,
        DST.SHIYO4                 = SRC.SHIYO4,
        DST.SHIYO5                 = SRC.SHIYO5,
        DST.SHIYO6                 = SRC.SHIYO6,
        DST.SAGYOSHA_FLG           = SRC.SAGYOSHA_FLG,
        DST.SETSUBI_FLG            = SRC.SETSUBI_FLG,
        DST.CHK_COMMENT_1          = SRC.CHK_COMMENT_1,
        DST.CHK_COMMENT_2          = SRC.CHK_COMMENT_2,
        DST.CHK_COMMENT_3          = SRC.CHK_COMMENT_3,
        DST.CHK_COMMENT_4          = SRC.CHK_COMMENT_4,
        DST.CHK_COMMENT_5          = SRC.CHK_COMMENT_5,
        DST.CHK_COMMENT_6          = SRC.CHK_COMMENT_6,
        DST.CHK_COMMENT_7          = SRC.CHK_COMMENT_7,
        DST.CHK_COMMENT_8          = SRC.CHK_COMMENT_8,
        DST.CHK_COMMENT_9          = SRC.CHK_COMMENT_9,
        DST.CHK_COMMENT_10         = SRC.CHK_COMMENT_10,
        DST.COMMENT_1              = SRC.COMMENT_1,
        DST.COMMENT_2              = SRC.COMMENT_2,
        DST.COMMENT_3              = SRC.COMMENT_3,
        DST.COMMENT_4              = SRC.COMMENT_4,
        DST.COMMENT_5              = SRC.COMMENT_5,
        DST.COMMENT_6              = SRC.COMMENT_6,
        DST.COMMENT_7              = SRC.COMMENT_7,
        DST.COMMENT_8              = SRC.COMMENT_8,
        DST.COMMENT_9              = SRC.COMMENT_9,
        DST.COMMENT_10             = SRC.COMMENT_10,
        DST.KANWARI_NO             = SRC.KANWARI_NO,
        DST.FURYO_TYPE             = SRC.FURYO_TYPE,
        DST.GYOMU_HANSU            = SRC.GYOMU_HANSU,
        DST.CHAKUSHU_FLG           = SRC.CHAKUSHU_FLG
        
    when not matched then
      insert (
        DST.COMPANYCD,
        DST.REGISTEREDPERSON,
        DST.REGISTEREDDT,
        DST.UPDATEDPERSON,
        DST.UPDATEDDT,
        DST.JIGYOBU_CD,
        DST.SEIHIN_BANGO,
        DST.KOTEI_TEJUN_CD,
        DST.KOUHOU_BANGO,
        DST.KOTEI_TEJUN_REV,
        DST.SO_NO,
        DST.KOTEI_BANGO,
        DST.KOTEI_CD,
        DST.KAKOU_TEJUN_REV,
        DST.KOTEI_NO,
        DST.JISSEKI_NYURYOKU_UMU,
        DST.JUNFUDO_GRP,
        DST.SHOCHISHIJI_NO,
        DST.SHIYO1,
        DST.SHIYO2,
        DST.SHIYO3,
        DST.SHIYO4,
        DST.SHIYO5,
        DST.SHIYO6,
        DST.SAGYOSHA_FLG,
        DST.SETSUBI_FLG,
        DST.CHK_COMMENT_1,
        DST.CHK_COMMENT_2,
        DST.CHK_COMMENT_3,
        DST.CHK_COMMENT_4,
        DST.CHK_COMMENT_5,
        DST.CHK_COMMENT_6,
        DST.CHK_COMMENT_7,
        DST.CHK_COMMENT_8,
        DST.CHK_COMMENT_9,
        DST.CHK_COMMENT_10,
        DST.COMMENT_1,
        DST.COMMENT_2,
        DST.COMMENT_3,
        DST.COMMENT_4,
        DST.COMMENT_5,
        DST.COMMENT_6,
        DST.COMMENT_7,
        DST.COMMENT_8,
        DST.COMMENT_9,
        DST.COMMENT_10,
        DST.KANWARI_NO,
        DST.FURYO_TYPE,
        DST.GYOMU_HANSU,
        DST.CHAKUSHU_FLG
      ) values (
        GET_COMPANY_CD,
        GET_USERNAME,
        GET_EXEC_DATE,
        GET_USERNAME,
        GET_EXEC_DATE,
        GET_JIGYOBU_CD,
        SRC.SEIHIN_BANGO,
        SRC.SEIHIN_BANGO,
        '0',
        '001',
        '00',
        SRC.KOTEI_BANGO,
        SRC.KOTEI_CD,
        '001',
        SRC.KOTEI_JUNBAN,
        SRC.HYOJUN_JISSEKI_NYURYOKU_UMU,
        SRC.KOTEI_GRP,
        '0000',
        SRC.SHIYO1,
        SRC.SHIYO2,
        SRC.SHIYO3,
        SRC.SHIYO4,
        SRC.SHIYO5,
        SRC.SHIYO6,
        SRC.SAGYOSHA_FLG,
        SRC.SETSUBI_FLG,
        SRC.CHK_COMMENT_1,
        SRC.CHK_COMMENT_2,
        SRC.CHK_COMMENT_3,
        SRC.CHK_COMMENT_4,
        SRC.CHK_COMMENT_5,
        SRC.CHK_COMMENT_6,
        SRC.CHK_COMMENT_7,
        SRC.CHK_COMMENT_8,
        SRC.CHK_COMMENT_9,
        SRC.CHK_COMMENT_10,
        SRC.COMMENT_1,
        SRC.COMMENT_2,
        SRC.COMMENT_3,
        SRC.COMMENT_4,
        SRC.COMMENT_5,
        SRC.COMMENT_6,
        SRC.COMMENT_7,
        SRC.COMMENT_8,
        SRC.COMMENT_9,
        SRC.COMMENT_10,
        SRC.KANWARI_NO,
        SRC.FURYO_TYPE,
        SRC.GYOMU_HANSU,
        SRC.CHAKUSHU_FLG
      );
    count_log;
    commit;
      -- 無効化していたインデックスを再構築
      execute IMMEDIATE 'alter index FDMAM26_I02 REBUILD';
    finish_log;
  end migrate_koutei_tejyun_kousei;

  -------------------------------------
  -- 文書マスタ更新用一時テーブルへの挿入
  -------------------------------------
  procedure insert_tempdoc(
      P_SEIHIN_BANGO     in PLMIG_TEMP_DOC.SEIHIN_BANGO%TYPE,
      P_KOTEI_BANGO      in PLMIG_TEMP_DOC.KOTEI_BANGO%TYPE,
      P_KOTEI_CD         in PLMIG_TEMP_DOC.KOTEI_CD%TYPE,
      doc_rec in csr_doc%ROWTYPE) as
  begin
    insert into PLMIG_TEMP_DOC values (
      P_SEIHIN_BANGO, P_SEIHIN_BANGO, P_KOTEI_BANGO, P_KOTEI_CD
      , doc_rec.BUNSHO_CD
      , doc_rec.DOC_NAME
      , doc_rec.DOC_CATEGORY
      , doc_rec.MI_URL
      , doc_rec.MI_KUBUN
      , doc_rec.MI_KOUKAI_KBN
      , doc_rec.MI_GAITYU_CODE
      , doc_rec.MI_KAKUNIN_KIKAN
      , doc_rec.PUBLISHED
    );
  exception
    when DUP_VAL_ON_INDEX then
      null; -- 共通文書配下の文書と親に直接の文書が同一の場合はあり得るので何もしません
  end;
  
  -------------------------------------
  -- 工程データから工程コードを参照
  -------------------------------------
  function get_koutei_cd(
      P_ITEM_CODE in PLMIG_C2_KOUTEI.ITEM_CODE%TYPE -- 品目番号
    ) return PLMIG_C2_KOUTEI.KOTEI_CD%TYPE
  as
    v_result PLMIG_C2_KOUTEI.KOTEI_CD%TYPE;
  begin
    select KOTEI_CD into v_result 
        from PLMIG_C2_KOUTEI
        where ITEM_CODE = P_ITEM_CODE;

    return v_result;

  exception
    when OTHERS then
      return '0';
  end;
  -------------------------------------
  -- 製品ノードに辿りつくまで再帰的に構成を検索
  -------------------------------------
  procedure find_docparent(
      P_NODE_CODE       IN PLMIG_C2_KOUSEI.KO_NODE_CODE%TYPE, 
      P_ITEM_CODE       IN PLMIG_C2_KOUSEI.KO_HINBAN%TYPE,
      P_KOTEI_BANGO     in PLMIG_TEMP_DOC.KOTEI_BANGO%TYPE,
      P_KOTEI_CD        in PLMIG_TEMP_DOC.KOTEI_CD%TYPE,
      doc_rec           in csr_doc%ROWTYPE,
      P_MAXRECURSIVE    in PLS_INTEGER) 
  as
    cursor cur_kousei is 
      select OYA_NODE_CODE, OYA_HINBAN 
        from PLMIG_C2_KOUSEI
        where KO_NODE_CODE = P_NODE_CODE and KO_HINBAN = P_ITEM_CODE;
    
    L_KOTEI_BANGO     PLMIG_TEMP_DOC.KOTEI_BANGO%TYPE := P_KOTEI_BANGO;
    L_KOTEI_CD        PLMIG_TEMP_DOC.KOTEI_CD%TYPE := P_KOTEI_CD;
  begin
    -- 再帰呼び出しが最大を超えたら終了
    if P_MAXRECURSIVE <= 0 then
      raise MAX_RECUSIVE_EXCEPTION;
    end if;
  
    -- 工程ノードに通りかかったらパラメータを置き換え
    if P_NODE_CODE = '9052' then
      L_KOTEI_BANGO := P_ITEM_CODE;
      L_KOTEI_CD := get_koutei_cd(P_ITEM_CODE);
    end if;
    
    for kousei_rec in cur_kousei loop
      if kousei_rec.OYA_NODE_CODE = '9022' then
        insert_tempdoc(kousei_rec.OYA_HINBAN, L_KOTEI_BANGO, L_KOTEI_CD, doc_rec);
      else
        -- 再帰で検索
        find_docparent(kousei_rec.OYA_NODE_CODE, kousei_rec.OYA_HINBAN, L_KOTEI_BANGO, L_KOTEI_CD, 
            doc_rec, P_MAXRECURSIVE - 1);
      end if;
    end loop;
  end;
  -------------------------------------
  -- 文書マスタ更新用一時テーブルの更新
  -------------------------------------
  procedure create_tempdoc 
  as 
  begin
    for doc_rec in csr_doc loop
      if doc_rec.P_NODE_CODE = '9022' then
        insert_tempdoc(doc_rec.ITEM_CODE, '0', '0', doc_rec);
      else
        find_docparent(doc_rec.P_NODE_CODE, doc_rec.ITEM_CODE, '0', '0', doc_rec, MAX_RECUSIVE);
      end if;
    end loop;

  exception
    when MAX_RECUSIVE_EXCEPTION then
      handle_error('9999', '再帰呼び出しが最大を超えました。');

    when migration_exception then
      handle_error('9999', 'データ移行の内部定義エラーです。');
  end;
  -------------------------------------
  -- 文書マスタの更新
  -------------------------------------
  procedure migrate_doc_master as 
  begin
    start_log('migrate_doc_master');
    -- 更新に邪魔なインデックスを一時的に無効化
    execute IMMEDIATE 'alter index TXBBD002_I02 UNUSABLE';
    -- ワークの表を切り捨て
    execute IMMEDIATE 'truncate table PLMIG_TEMP_DOC';
    -- 文書マスタ更新用一時テーブルの更新
    create_tempdoc;
    
    --
    merge into TXBBD002 DST 
    using PLMIG_TEMP_DOC SRC
    on (    DST.SEIHIN_BANGO  = SRC.SEIHIN_BANGO
        and DST.KOTEI_BANGO   = SRC.KOTEI_BANGO
        and DST.BUNSHO_CD     = SRC.BUNSHO_CD
        and DST.COMPANYCD     = GET_COMPANY_CD 
        and DST.JIGYOBU_CD    = GET_JIGYOBU_CD)
    when matched then
      update set
        DST.UPDATEDPERSON        =  GET_USERNAME,
        DST.UPDATEDDT            =  GET_EXEC_DATE,
        DST.HINMOKU_CD           =  SRC.SEIHIN_BANGO,
        DST.KOTEI_CD             =  SRC.KOTEI_CD,
        DST.BUNSHO_NAME          =  SRC.DOC_NAME,
        DST.BUNSHO_BUNRUI        =  SRC.DOC_CATEGORY,
        DST.URL                  =  SRC.MI_URL,
        DST.HISSU_FLG            =  SRC.MI_KUBUN,
        DST.KOUKAI_KBN           =  SRC.MI_KOUKAI_KBN,
        DST.KOUKAI_GAITYU_CD     =  SRC.MI_GAITYU_CODE,
        DST.KAKUNIN_KIKAN        =  SRC.MI_KAKUNIN_KIKAN,
        DST.FILE_UPDATED_DATE    =  GET_EXEC_DATE,
        DST.SHONIN_DATE          =  SRC.PUBLISHED
        
    when not matched then
      insert (
        DST.COMPANYCD,
        DST.REGISTEREDPERSON,
        DST.REGISTEREDDT,
        DST.UPDATEDPERSON,
        DST.UPDATEDDT,
        DST.JIGYOBU_CD,
        DST.SEIHIN_BANGO,
        DST.HINMOKU_CD,
        DST.KOUHOU_BANGO,
        DST.KOTEI_BANGO,
        DST.KOTEI_CD,
        DST.BUNSHO_CD,
        DST.BUNSHO_NAME,
        DST.BUNSHO_BUNRUI,
        DST.URL,
        DST.HISSU_FLG,
        DST.KOUKAI_KBN,
        DST.KOUKAI_GAITYU_CD,
        DST.KAKUNIN_KIKAN,
        DST.FILE_UPDATED_DATE,
        DST.SHONIN_DATE
      ) values (
        GET_COMPANY_CD,
        GET_USERNAME,
        GET_EXEC_DATE,
        GET_USERNAME,
        GET_EXEC_DATE,
        GET_JIGYOBU_CD,
        SRC.SEIHIN_BANGO,
        SRC.SEIHIN_BANGO,
        '0',
        SRC.KOTEI_BANGO,
        SRC.KOTEI_CD,
        SRC.BUNSHO_CD,
        SRC.DOC_NAME,
        SRC.DOC_CATEGORY,
        SRC.MI_URL,
        SRC.MI_KUBUN,
        SRC.MI_KOUKAI_KBN,
        SRC.MI_GAITYU_CODE,
        SRC.MI_KAKUNIN_KIKAN,
        GET_EXEC_DATE,
        SRC.PUBLISHED
      );
    count_log;
    commit;
    -- 無効化していたインデックスを再構築
    execute IMMEDIATE 'alter index TXBBD002_I02 REBUILD';
    finish_log;
  end migrate_doc_master;
  
  --------------------------------------------------------------
  -- 管理項目マスタの管理項目値以外の値のセット
  --------------------------------------------------------------
  procedure set_kanri_items_seihin as 
  begin
    g_kanri_rec_master.COMPANYCD           :=  GET_COMPANY_CD;
    g_kanri_rec_master.REGISTEREDPERSON    :=  GET_USERNAME;
    g_kanri_rec_master.REGISTEREDDT        :=  GET_EXEC_DATE;
    g_kanri_rec_master.UPDATEDPERSON       :=  GET_USERNAME;
    g_kanri_rec_master.UPDATEDDT           :=  GET_EXEC_DATE;
    g_kanri_rec_master.JIGYOBU_CD          :=  GET_JIGYOBU_CD;
    g_kanri_rec_master.KOUHOU_BANGO        := '0';
    g_kanri_rec_master.KOTEI_BANGO         := '0';
    g_kanri_rec_master.KOTEI_CD            := '0';
    g_kanri_rec_master.KOTEI_FUTAI_BANGO   := '0';
    g_kanri_rec_master.KOTEI_FUTAI_CD      := '0';
  end set_kanri_items_seihin;

  --------------------------------------------------------------
  -- 管理項目マスタの管理項目値以外の値のセット
  --------------------------------------------------------------
  procedure set_kanri_keys_seihin(rec in PLMIG_C2_SEIHIN%ROWTYPE) as 
  begin
    g_kanri_rec_master.SEIHIN_BANGO        :=  rec.ITEM_CODE;
    g_kanri_rec_master.HINMOKU_CD          :=  rec.ITEM_CODE;
  end set_kanri_keys_seihin;

  --------------------------------------------------------------
  -- 管理項目マスタのレコード更新
  --------------------------------------------------------------
  procedure update_kanrikoumku_seihin(item_cd in varchar2, item_name in varchar2, item_value in varchar2) as 
  begin
    if item_value is null then
      return;
    end if;
    g_bulk_ix := g_bulk_ix + 1;
    
    g_kanri_rec(g_bulk_ix) := g_kanri_rec_master;
    g_kanri_rec(g_bulk_ix).KANRI_KOMOKU_CD := item_cd;
    g_kanri_rec(g_bulk_ix).KANRI_KOMOKU_MEI := item_name;
    g_kanri_rec(g_bulk_ix).KANRI_KOMOKU_CHI := item_value;
    
    -- バルクインサートのバッファがいっぱいになったらインサート
    if g_bulk_ix >= BULK_SIZE_CONST then
      forall i in g_kanri_rec.FIRST .. g_kanri_rec.LAST
        insert into TXBBM001 values g_kanri_rec(i);
      commit;
      g_kanri_rec.delete;
      g_bulk_ix := 0;
    end if;

  exception
    when others then
      handle_error(SQLCODE, SQLERRM);
      rollback;
  end update_kanrikoumku_seihin;

  --------------------------------------------------------------
  -- 管理項目マスタのレコード更新（日付型）
  --------------------------------------------------------------
  procedure update_kanrikoumku_seihin(item_cd in varchar2, item_name in varchar2, item_value in date) as 
  begin
    -- 書式化された文字列に変換
    update_kanrikoumku_seihin(item_cd, item_name, TO_CHAR(item_value, 'YYYY/MM/DD HH24:MI:SS'));
  end update_kanrikoumku_seihin;

  --------------------------------------------------------------
  -- 管理項目マスタ更新(製品)
  --------------------------------------------------------------
  procedure migrate_kanrikoumoku_seihin as 
    cursor cur_seihin is select * from PLMIG_C2_SEIHIN ; 
    type TYP_SEIHIN_TBL IS TABLE OF cur_seihin%ROWTYPE INDEX BY BINARY_INTEGER;
    SEIHIN_TBL TYP_SEIHIN_TBL;
  begin
    start_log('migrate_kanrikoumoku_seihin');
    -- 固定的項目値をセット
    set_kanri_items_seihin;

    -- インデックスを一時的に無効化
    execute IMMEDIATE 'alter index TXBBM001_I02 UNUSABLE';

    -- 一旦追加しようとしている分を消去
    open cur_seihin;
    loop
      fetch cur_seihin BULK COLLECT into  SEIHIN_TBL LIMIT 1000;
      exit when SEIHIN_TBL.COUNT = 0;
      
      forall i in SEIHIN_TBL.first .. SEIHIN_TBL.last
        delete from TXBBM001 DEST
          where DEST.SEIHIN_BANGO = SEIHIN_TBL(i).ITEM_CODE
          and DEST.COMPANYCD = get_company_cd
          and DEST.JIGYOBU_CD = get_jigyobu_cd
          and DEST.KOUHOU_BANGO = '0'
          and DEST.KOTEI_BANGO = '0'
          and DEST.KOTEI_FUTAI_BANGO = '0';
  
      commit;
    end loop;
    close cur_seihin;

    g_bulk_ix := 0;
    g_kanri_rec.delete;
    
    for seihin_rec in cur_seihin loop
      -- キー項目をセット
      set_kanri_keys_seihin(seihin_rec);
      
      update_kanrikoumku_seihin('10042001','業務版数',                      seihin_rec.GYOMU_HANSU);
      update_kanrikoumku_seihin('10042002','班コード',                      seihin_rec.HAN_CD);
      update_kanrikoumku_seihin('10042003','共通品',                        seihin_rec.KYOTSU_HIN);
      update_kanrikoumku_seihin('10042004','KeyNo.',                        seihin_rec.KEYNO_MCODE);
      update_kanrikoumku_seihin('10042006','管理番号',                      seihin_rec.KANRI_BANGO);
      update_kanrikoumku_seihin('10042007','略式orパーツNo',                seihin_rec.OLD_KEYNO);
      update_kanrikoumku_seihin('10042008','客先コード:客先名称',           seihin_rec.KYAKUSAKI_CD);
      update_kanrikoumku_seihin('10042010','客先名（入力）',                seihin_rec.KYAKUSAKI_MEI_NYURYOKU);
      update_kanrikoumku_seihin('10042312','品名',                          seihin_rec.HINMEI);
      update_kanrikoumku_seihin('10042095','社内図番',                      seihin_rec.ZUBAN);
      update_kanrikoumku_seihin('10042096','社外図番',                      seihin_rec.SHAGAI_ZUBAN);
      update_kanrikoumku_seihin('10042114','材質コード',                    seihin_rec.ZAISHITSU_CD);
      update_kanrikoumku_seihin('10042117','詳細材質コード',                seihin_rec.SYOUSAI_ZAISHITSU_CD);
      update_kanrikoumku_seihin('10042016','客先パーツNo.',                 seihin_rec.KYAKUSAKI_PARTS_NO);
      update_kanrikoumku_seihin('10042019','備考',                          seihin_rec.BIKO);
      update_kanrikoumku_seihin('10042020','KCパーツNo.',                   seihin_rec.KC_PARTS_NO);
      update_kanrikoumku_seihin('10042022','単位変換（区分）',              seihin_rec.TANI_HENKAN_KBN);
      update_kanrikoumku_seihin('10045001','単位変換（数値）',              seihin_rec.TANI_HENKAN);
      update_kanrikoumku_seihin('10042023','セットフラグ',                  seihin_rec.SET_FLG);
      update_kanrikoumku_seihin('10042024','タイプ',                        seihin_rec.TYPE);
      update_kanrikoumku_seihin('10042097','状態',                          seihin_rec.JYOTAI);
      update_kanrikoumku_seihin('10042025','共通仕様１',                    seihin_rec.KYOTSU_SHIYO_1);
      update_kanrikoumku_seihin('10042026','共通仕様２',                    seihin_rec.KYOTSU_SHIYO_2);
      update_kanrikoumku_seihin('10042027','共通仕様３',                    seihin_rec.KYOTSU_SHIYO_3);
      update_kanrikoumku_seihin('10042028','スペック１',                    seihin_rec.SPEC1);
      update_kanrikoumku_seihin('10042029','スペック２',                    seihin_rec.SPEC2);
      update_kanrikoumku_seihin('10042030','スペック３',                    seihin_rec.SPEC3);
      update_kanrikoumku_seihin('10042031','引落し工程',                    seihin_rec.HIKIOTOSHI_KOTEI);
      update_kanrikoumku_seihin('10042032','原産国',                        seihin_rec.GENZANKOKU);
      update_kanrikoumku_seihin('10042033','工程なし品',                    seihin_rec.KOTEI_NASHI_HIN);
      update_kanrikoumku_seihin('10042034','有効フラグ',                    seihin_rec.YUKO_FLG);
      update_kanrikoumku_seihin('10042316','分類',                          seihin_rec.BUNRUI);
      update_kanrikoumku_seihin('10046001','停止日/開始日',                 seihin_rec.TEISHI_KAISHI);
      update_kanrikoumku_seihin('10044001','科目',                          seihin_rec.KAMOKU);
      update_kanrikoumku_seihin('10042035','金型代の有無',                  seihin_rec.KANAGATA_UMU);
      update_kanrikoumku_seihin('10045013','外寸（縦）:mm',                 seihin_rec.GAISUN_TATE);
      update_kanrikoumku_seihin('10045014','外寸（横）:mm',                 seihin_rec.GAISUN_YOKO);
      update_kanrikoumku_seihin('10045015','外寸（高さ）:mm',               seihin_rec.GAISUN_TAKASA);
      update_kanrikoumku_seihin('10045016','外径（φ）:mm',                 seihin_rec.GAIKEI);
      update_kanrikoumku_seihin('10045017','内径（φ）:mm',                 seihin_rec.NAIKEI);
      update_kanrikoumku_seihin('10042036','形状',                          seihin_rec.KEIJYO);
      update_kanrikoumku_seihin('10042037','材質分類',                      seihin_rec.ZAISHITSU_BUNRUI);
      update_kanrikoumku_seihin('10042038','材質外観',                      seihin_rec.ZAISHITSU_GAIKAN);
      update_kanrikoumku_seihin('10042039','ﾒﾀ、釉薬の有無',                seihin_rec.META_YUYAKU_UMU);
      update_kanrikoumku_seihin('10042040','切削加工有無',                  seihin_rec.SESSAKU_KAKO_UMU);
      update_kanrikoumku_seihin('10042041','研削加工有無',                  seihin_rec.KENSAKU_KAKO_UMU);
      update_kanrikoumku_seihin('10042042','厚み研磨加工有無',              seihin_rec.ATSUMI_KENMA_KAKO_UMU);
      update_kanrikoumku_seihin('10042043','ｾﾝﾀﾚｽ研磨加工有無',             seihin_rec.CENTERLESS_KENMA_KAKO_UMU);
      update_kanrikoumku_seihin('10042044','金型構造（上パンチ）',          seihin_rec.KANAGATA_KOZO_UE_PUNCH);
      update_kanrikoumku_seihin('10042045','金型構造(下パンチ)',            seihin_rec.KANAGATA_KOZO_SHITA_PUNCH);
      update_kanrikoumku_seihin('10042046','金型構造(ウス)',                seihin_rec.KANAGATA_KOZO_USU);
      update_kanrikoumku_seihin('10042047','金型構造(コア)',                seihin_rec.KANAGATA_KOZO_CORE);
      update_kanrikoumku_seihin('10042048','ﾌﾟﾚｽ機種',                      seihin_rec.PRESS_KISHU);
      update_kanrikoumku_seihin('10042049','ｔｏｎ数',                      seihin_rec.TON_SU);
      update_kanrikoumku_seihin('10042050','品種／用途',                    seihin_rec.HINSHU_YOTO);
      update_kanrikoumku_seihin('10042051','金型番号',                      seihin_rec.KANAGATA_BANGO);
      update_kanrikoumku_seihin('10042052','顧客地域',                      seihin_rec.KOKYAKU_AREA);
      update_kanrikoumku_seihin('10042053','誘電体　旧ｋｅｙ　Ｎｏ．',      seihin_rec.YUDENTAI_OLD_KEYNO);
      update_kanrikoumku_seihin('10045007','数量',                          seihin_rec.SURYO);
      update_kanrikoumku_seihin('10045008','価格',                          seihin_rec.KAKAKU);
      update_kanrikoumku_seihin('10042054','技術要素',                      seihin_rec.GIJUTSU_YOSO);
      update_kanrikoumku_seihin('10042055','不具合の種類',                  seihin_rec.FUGUAI_SHURUI);
      update_kanrikoumku_seihin('10042102','治具代・ﾂｰﾙ代の有無',           seihin_rec.JIGU_TOOL_DAI_UMU);
      update_kanrikoumku_seihin('10042103','測定方法',                      seihin_rec.SOKUTEI_PLAN);
      update_kanrikoumku_seihin('10042104','寸法タイト',                    seihin_rec.SUNPOU_TIGHT);
      update_kanrikoumku_seihin('10042105','梱包方法',                      seihin_rec.KONPO_PLAN);
      update_kanrikoumku_seihin('10042106','ﾒｯｷの有無',                     seihin_rec.MEKKI_UMU);
      update_kanrikoumku_seihin('10042107','ｶｯﾀｰの有無',                    seihin_rec.KATTA_UMU);
      update_kanrikoumku_seihin('10042108','ｽﾙｰﾎｰﾙ径（φ）：mm',            seihin_rec.THROUGH_HOLE_DIAMETER);
      update_kanrikoumku_seihin('10042057','見積台帳番号',                  seihin_rec.MITSUMORI_DAICHO_BANGO);
      update_kanrikoumku_seihin('10042058','見積台帳版数',                  seihin_rec.MITSUMORI_DAICHO_HANSU);
      update_kanrikoumku_seihin('10042059','見積時客先名',                  seihin_rec.MITSUMORIJI_KYAKUSAKI_MEI);
      update_kanrikoumku_seihin('10042109','暫定単価',                      seihin_rec.ZANTEI_TANKA);
      update_kanrikoumku_seihin('10042075','チェックコメント（１）',        seihin_rec.CHK_COMMENT_1);
      update_kanrikoumku_seihin('10042076','チェックコメント（２）',        seihin_rec.CHK_COMMENT_2);
      update_kanrikoumku_seihin('10042077','チェックコメント（３）',        seihin_rec.CHK_COMMENT_3);
      update_kanrikoumku_seihin('10042085','コメント（１）',                seihin_rec.COMMENT_1);
      update_kanrikoumku_seihin('10042086','コメント（２）',                seihin_rec.COMMENT_2);
      update_kanrikoumku_seihin('10042087','コメント（３）',                seihin_rec.COMMENT_3);
      update_kanrikoumku_seihin('10042061','一括工程変更実施',              seihin_rec.IKKATU_KOUTEI_CHG);

      update_kanrikoumku_seihin('10046002','移行元登録日',                  seihin_rec.IKOU_MOTO_DATE);
      update_kanrikoumku_seihin('10042060','移行元登録者',                  seihin_rec.IKO_MOTO_TOUROKU);
      update_kanrikoumku_seihin('10030014','登録日',              GET_EXEC_DATE);
      update_kanrikoumku_seihin('10042470','登録者',              GET_USERNAME);
      update_kanrikoumku_seihin('10042467','登録部署',            '0');
      update_kanrikoumku_seihin('10030060','更新日',              GET_EXEC_DATE);
      update_kanrikoumku_seihin('10042471','更新者',              GET_USERNAME);
      update_kanrikoumku_seihin('10042468','更新部署',            '0');
      update_kanrikoumku_seihin('10030084','承認日',              GET_EXEC_DATE);
      update_kanrikoumku_seihin('10042472','承認者',              GET_USERNAME);
      update_kanrikoumku_seihin('10042469','承認部署',            '0');
      
    end loop;
    
    -- バルクインサートのバッファの残りを更新
    forall i in g_kanri_rec.FIRST .. g_kanri_rec.LAST
      insert into TXBBM001 values g_kanri_rec(i);
    commit;
    
    -- インデックスを最有効化
    execute IMMEDIATE 'alter index TXBBM001_I02 REBUILD';
    finish_log;
  end migrate_kanrikoumoku_seihin;
  
  --------------------------------------------------------------
  -- 管理項目マスタ(工程)の管理項目値以外の値のセット
  --------------------------------------------------------------
  procedure set_kanri_items_koutei as 
  begin
    g_kanri_rec_master.COMPANYCD           :=  GET_COMPANY_CD;
    g_kanri_rec_master.REGISTEREDPERSON    :=  GET_USERNAME;
    g_kanri_rec_master.REGISTEREDDT        :=  GET_EXEC_DATE;
    g_kanri_rec_master.UPDATEDPERSON       :=  GET_USERNAME;
    g_kanri_rec_master.UPDATEDDT           :=  GET_EXEC_DATE;
    g_kanri_rec_master.JIGYOBU_CD          :=  GET_JIGYOBU_CD;
    g_kanri_rec_master.KOUHOU_BANGO        := '0';
    g_kanri_rec_master.KOTEI_FUTAI_BANGO   := '0';
    g_kanri_rec_master.KOTEI_FUTAI_CD      := '0';
  end set_kanri_items_koutei;

  --------------------------------------------------------------
  -- 管理項目マスタ(工程)の管理項目値以外の値のセット
  --------------------------------------------------------------
  procedure set_kanri_keys_koutei(rec in PLMIG_V_C2_TEJUNKOUSEI%ROWTYPE) as 
  begin
    g_kanri_rec_master.SEIHIN_BANGO        :=  rec.SEIHIN_BANGO;
    g_kanri_rec_master.HINMOKU_CD          :=  rec.SEIHIN_BANGO;
    g_kanri_rec_master.KOTEI_BANGO         :=  rec.KOTEI_BANGO;
    g_kanri_rec_master.KOTEI_CD            :=  rec.KOTEI_CD;
  end set_kanri_keys_koutei;

  --------------------------------------------------------------
  -- 管理項目マスタ(工程)のレコード更新
  --------------------------------------------------------------
  procedure update_kanrikoumku_koutei(item_cd in varchar2, item_name in varchar2, item_value in varchar2,
        bulk_flash in boolean := false  -- 最後の項目でtrueにセットする
  ) as 
  begin
    if item_value is null then
      return;
    end if;
    g_bulk_ix := g_bulk_ix + 1;
    
    g_kanri_rec(g_bulk_ix) := g_kanri_rec_master;
    g_kanri_rec(g_bulk_ix).KANRI_KOMOKU_CD := item_cd;
    g_kanri_rec(g_bulk_ix).KANRI_KOMOKU_MEI := item_name;
    g_kanri_rec(g_bulk_ix).KANRI_KOMOKU_CHI := item_value;
    
    -- バルクインサートのバッファがいっぱいになったらインサート
    if (g_bulk_ix >= BULK_SIZE_CONST) or (bulk_flash = true) then
      forall i in g_kanri_rec.FIRST .. g_kanri_rec.LAST
        insert into TXBBM001 values g_kanri_rec(i);
      commit;
      g_kanri_rec.delete;
      g_bulk_ix := 0;
    end if;

  exception
    when others then
      handle_error(SQLCODE, SQLERRM);
      rollback;
  end update_kanrikoumku_koutei;

  --------------------------------------------------------------
  -- 管理項目マスタ(工程)のレコード更新（日付型）
  --------------------------------------------------------------
  procedure update_kanrikoumku_koutei(item_cd in varchar2, item_name in varchar2, item_value in date) as 
  begin
    -- 書式化された文字列に変換
    update_kanrikoumku_koutei(item_cd, item_name, TO_CHAR(item_value, 'YYYY/MM/DD HH24:MI:SS'));
  end update_kanrikoumku_koutei;
  
  --------------------------------------------------------------
  -- 管理項目マスタ更新(工程)
  --------------------------------------------------------------
  procedure migrate_kanrikoumoku_koutei as 
    cursor cur_koutei is select * from PLMIG_V_C2_TEJUNKOUSEI ; 
    type TYP_KOUTEI_TBL IS TABLE OF cur_koutei%ROWTYPE INDEX BY BINARY_INTEGER;
    KOUTEI_TBL TYP_KOUTEI_TBL;
  begin
    start_log('migrate_kanrikoumoku_koutei');
    -- 固定的項目値をセット
    set_kanri_items_koutei;

    -- インデックスを一時的に無効化
    execute IMMEDIATE 'alter index TXBBM001_I02 UNUSABLE';

    -- 一旦追加しようとしている分を消去
    open cur_koutei;
    loop
      fetch cur_koutei BULK COLLECT into  KOUTEI_TBL LIMIT 1000;
      exit when KOUTEI_TBL.COUNT = 0;
      
      forall i in KOUTEI_TBL.first .. KOUTEI_TBL.last
        delete from TXBBM001 DEST
          where DEST.SEIHIN_BANGO = KOUTEI_TBL(i).SEIHIN_BANGO
          and DEST.COMPANYCD = get_company_cd
          and DEST.JIGYOBU_CD = get_jigyobu_cd
          and DEST.KOUHOU_BANGO = '0'
          and DEST.KOTEI_BANGO = KOUTEI_TBL(i).KOTEI_BANGO
          and DEST.KOTEI_FUTAI_BANGO = '0';
  
      commit;
    end loop;
    close cur_koutei;

    g_bulk_ix := 0;
    g_kanri_rec.delete;
    
    for koutei_rec in cur_koutei loop
      -- キー項目をセット
      set_kanri_keys_koutei(koutei_rec);
      
      update_kanrikoumku_koutei('10042001','業務版数', koutei_rec.GYOMU_HANSU);
      update_kanrikoumku_koutei('10042062','工程コード', koutei_rec.KOTEI_CD);
      update_kanrikoumku_koutei('10042072','実績入力有無', koutei_rec.HYOJUN_JISSEKI_NYURYOKU_UMU);
      update_kanrikoumku_koutei('10042073','作業者フラグ', koutei_rec.SAGYOSHA_FLG);
      update_kanrikoumku_koutei('10042074','設備フラグ', koutei_rec.SETSUBI_FLG);
      update_kanrikoumku_koutei('10042075','チェックコメント（１）', koutei_rec.CHK_COMMENT_1);
      update_kanrikoumku_koutei('10042076','チェックコメント（２）', koutei_rec.CHK_COMMENT_2);
      update_kanrikoumku_koutei('10042077','チェックコメント（３）', koutei_rec.CHK_COMMENT_3);
      update_kanrikoumku_koutei('10042078','チェックコメント（４）', koutei_rec.CHK_COMMENT_4);
      update_kanrikoumku_koutei('10042079','チェックコメント（５）', koutei_rec.CHK_COMMENT_5);
      update_kanrikoumku_koutei('10042080','チェックコメント（６）', koutei_rec.CHK_COMMENT_6);
      update_kanrikoumku_koutei('10042081','チェックコメント（７）', koutei_rec.CHK_COMMENT_7);
      update_kanrikoumku_koutei('10042082','チェックコメント（８）', koutei_rec.CHK_COMMENT_8);
      update_kanrikoumku_koutei('10042083','チェックコメント（９）', koutei_rec.CHK_COMMENT_9);
      update_kanrikoumku_koutei('10042084','チェックコメント（１０）', koutei_rec.CHK_COMMENT_10);
      update_kanrikoumku_koutei('10042085','コメント（１）', koutei_rec.COMMENT_1);
      update_kanrikoumku_koutei('10042086','コメント（２）', koutei_rec.COMMENT_2);
      update_kanrikoumku_koutei('10042087','コメント（３）', koutei_rec.COMMENT_3);
      update_kanrikoumku_koutei('10042088','コメント（４）', koutei_rec.COMMENT_4);
      update_kanrikoumku_koutei('10042089','コメント（５）', koutei_rec.COMMENT_5);
      update_kanrikoumku_koutei('10042090','コメント（６）', koutei_rec.COMMENT_6);
      update_kanrikoumku_koutei('10042091','コメント（７）', koutei_rec.COMMENT_7);
      update_kanrikoumku_koutei('10042092','コメント（８）', koutei_rec.COMMENT_8);
      update_kanrikoumku_koutei('10042093','コメント（９）', koutei_rec.COMMENT_9);
      update_kanrikoumku_koutei('10042094','コメント（１０）', koutei_rec.COMMENT_10);
      update_kanrikoumku_koutei('10042066','仕様１', koutei_rec.SHIYO1);
      update_kanrikoumku_koutei('10042067','仕様２', koutei_rec.SHIYO2);
      update_kanrikoumku_koutei('10042068','仕様３', koutei_rec.SHIYO3);
      update_kanrikoumku_koutei('10042069','仕様４', koutei_rec.SHIYO4);
      update_kanrikoumku_koutei('10042070','仕様５', koutei_rec.SHIYO5);
      update_kanrikoumku_koutei('10042071','仕様６', koutei_rec.SHIYO6);
      update_kanrikoumku_koutei('10042110','完割NO.',  koutei_rec.KANWARI_NO);
      update_kanrikoumku_koutei('10042111','不良Type', koutei_rec.FURYO_TYPE);
      update_kanrikoumku_koutei('10042306','着手フラグ', koutei_rec.CHAKUSHU_FLG);
      update_kanrikoumku_koutei('10042064','工程名', koutei_rec.KOTEI_MEI);
      update_kanrikoumku_koutei('10046002','移行元登録日', GET_EXEC_DATE);
      update_kanrikoumku_koutei('10042060','移行元登録者', GET_USERNAME);
      update_kanrikoumku_koutei('10030014','登録日', GET_EXEC_DATE);
      update_kanrikoumku_koutei('10042470','登録者', GET_USERNAME);
      update_kanrikoumku_koutei('10042467','登録部署', '0');
      update_kanrikoumku_koutei('10030060','更新日', GET_EXEC_DATE);
      update_kanrikoumku_koutei('10042471','更新者', GET_USERNAME);
      update_kanrikoumku_koutei('10042468','更新部署', '0');
      update_kanrikoumku_koutei('10030084','承認日', GET_EXEC_DATE);
      update_kanrikoumku_koutei('10042472','承認者', GET_USERNAME);
      update_kanrikoumku_koutei('10042469','承認部署', '0', true);
      
    end loop;
    
    -- バルクインサートのバッファの残りを更新
    forall i in g_kanri_rec.FIRST .. g_kanri_rec.LAST
      insert into TXBBM001 values g_kanri_rec(i);
    commit;
    
    -- インデックスを最有効化
    execute IMMEDIATE 'alter index TXBBM001_I02 REBUILD';
    finish_log;
  end migrate_kanrikoumoku_koutei;
  
  --------------------------------------------------------------
  -- 管理項目マスタ(部品)の管理項目値以外の値のセット
  --------------------------------------------------------------
  procedure set_kanri_items_buhin as 
  begin
    g_kanri_rec_master.COMPANYCD           :=  GET_COMPANY_CD;
    g_kanri_rec_master.REGISTEREDPERSON    :=  GET_USERNAME;
    g_kanri_rec_master.REGISTEREDDT        :=  GET_EXEC_DATE;
    g_kanri_rec_master.UPDATEDPERSON       :=  GET_USERNAME;
    g_kanri_rec_master.UPDATEDDT           :=  GET_EXEC_DATE;
    g_kanri_rec_master.JIGYOBU_CD          :=  GET_JIGYOBU_CD;
    g_kanri_rec_master.KOUHOU_BANGO        := '0';
  end set_kanri_items_buhin;

  --------------------------------------------------------------
  -- 管理項目マスタ(部品)の管理項目値以外の値のセット
  --------------------------------------------------------------
  procedure set_kanri_keys_buhin(rec in PLMIG_V_C2_KANRI_BUHIN_PARENT%ROWTYPE) as 
  begin
    g_kanri_rec_master.SEIHIN_BANGO        :=  rec.SEIHIN_BANGO;
    g_kanri_rec_master.HINMOKU_CD          :=  rec.SEIHIN_BANGO;
    g_kanri_rec_master.KOTEI_BANGO         :=  rec.KOUTEI_BANGO;
    g_kanri_rec_master.KOTEI_CD            :=  rec.KOTEI_CD;
  end set_kanri_keys_buhin;

  --------------------------------------------------------------
  -- 管理項目マスタ(部品)の管理項目値以外の値のセット
  --------------------------------------------------------------
  procedure set_kanri_keys_buhin(rec in PLMIG_V_C2_KANRI_BUHIN_CHILD%ROWTYPE) as 
  begin
    g_kanri_rec_master.KOTEI_FUTAI_BANGO   := rec.BUHIN_BANGO;
    g_kanri_rec_master.KOTEI_FUTAI_CD      := rec.BUHIN_CD;
  end set_kanri_keys_buhin;

  --------------------------------------------------------------
  -- 管理項目マスタ(部品)のレコード更新
  --------------------------------------------------------------
  procedure update_kanrikoumku_buhin(item_cd in varchar2, item_name in varchar2, item_value in varchar2, 
      bulk_flash in boolean := false  -- 最後の項目でtrueにセットする
      ) as 
  begin
    if item_value is null then
      return;
    end if;
    g_bulk_ix := g_bulk_ix + 1;
    
    g_kanri_rec(g_bulk_ix) := g_kanri_rec_master;
    g_kanri_rec(g_bulk_ix).KANRI_KOMOKU_CD := item_cd;
    g_kanri_rec(g_bulk_ix).KANRI_KOMOKU_MEI := item_name;
    g_kanri_rec(g_bulk_ix).KANRI_KOMOKU_CHI := item_value;
    
    -- バルクインサートのバッファがいっぱいになったらインサート
    if (g_bulk_ix >= BULK_SIZE_CONST) or (bulk_flash = true) then
      forall i in g_kanri_rec.FIRST .. g_kanri_rec.LAST  --save exceptions
        insert into TXBBM001 values g_kanri_rec(i);
      commit;
      g_kanri_rec.delete;
      g_bulk_ix := 0;
    end if;

  exception
    when others then
      rollback;
      handle_error(SQLCODE, SQLERRM);
  end update_kanrikoumku_buhin;

  --------------------------------------------------------------
  -- 管理項目マスタ(部品)のレコード更新（日付型）
  --------------------------------------------------------------
  procedure update_kanrikoumku_buhin(item_cd in varchar2, item_name in varchar2, item_value in date) as 
  begin
    -- 書式化された文字列に変換
    update_kanrikoumku_buhin(item_cd, item_name, TO_CHAR(item_value, 'YYYY/MM/DD HH24:MI:SS'));
  end update_kanrikoumku_buhin;

  --------------------------------------------------------------
  -- 管理項目マスタ更新(部品) ー　再帰処理用
  --------------------------------------------------------------
  procedure migrate_kanrikoumoku_buhin_sub(parent_bango in varchar2, depth_limit in integer) as 
    cursor cur_buhin is 
      select * from PLMIG_V_C2_KANRI_BUHIN_CHILD 
      where OYA_HINBAN = parent_bango; 
  begin
    if (depth_limit <= 0) then
      return;
    end if;
    
    for buhin_rec in cur_buhin loop
      -- キー項目をセット
      set_kanri_keys_buhin(buhin_rec);
      -- 一旦削除
      delete from TXBBM001 where
          COMPANYCD           =   g_kanri_rec_master.COMPANYCD and
          JIGYOBU_CD          =   g_kanri_rec_master.JIGYOBU_CD and
          SEIHIN_BANGO        =   g_kanri_rec_master.SEIHIN_BANGO and
          KOTEI_BANGO         =   g_kanri_rec_master.KOTEI_BANGO and
          KOTEI_FUTAI_BANGO   =   g_kanri_rec_master.KOTEI_FUTAI_BANGO;
      commit;
      
      update_kanrikoumku_buhin('10042001', '業務版数',                  buhin_rec.GYOMU_HANSU);
      update_kanrikoumku_buhin('10042134', '部品コード',                buhin_rec.BUHIN_CD);
      update_kanrikoumku_buhin('10042135', '部品名',                    buhin_rec.BUHIN_MEI);
      update_kanrikoumku_buhin('10042136', '部品図番',                  buhin_rec.BUHIN_ZUBAN);
      update_kanrikoumku_buhin('10042116', '材質コード',                buhin_rec.ZAISHITSU_CD_BUHIN);
      update_kanrikoumku_buhin('10042137', '仕入先コード:仕入先名称',   buhin_rec.SHIIRESAKI_CD_BUHIN);
      update_kanrikoumku_buhin('10042138', '仕入先名（入力）',          buhin_rec.SHIIRESAKI_MEI_BUHIN);
      update_kanrikoumku_buhin('10045012', '金額',                      buhin_rec.KINGAKU_BUHIN);
      update_kanrikoumku_buhin('10042139', '部材区分',                  buhin_rec.BUZAI_KBN);
      update_kanrikoumku_buhin('10042018', '備考',                      buhin_rec.BIKO_BUHIN);
      update_kanrikoumku_buhin('10046002', '移行元登録日',              buhin_rec.IKOU_MOTO_DATE);
      update_kanrikoumku_buhin('10042060', '移行元登録者',              buhin_rec.IKO_MOTO_TOUROKU);
      update_kanrikoumku_buhin('10030014', '登録日',                    GET_EXEC_DATE);
      update_kanrikoumku_buhin('10042470', '登録者',                    GET_USERNAME);
      update_kanrikoumku_buhin('10042467', '登録部署',                  '0');
      update_kanrikoumku_buhin('10030060', '更新日',                    GET_EXEC_DATE);
      update_kanrikoumku_buhin('10042471', '更新者',                    GET_USERNAME);
      update_kanrikoumku_buhin('10042468', '更新部署',                  '0');
      update_kanrikoumku_buhin('10030084', '承認日',                    GET_EXEC_DATE);
      update_kanrikoumku_buhin('10042472', '承認者',                    GET_USERNAME);
      update_kanrikoumku_buhin('10042469', '承認部署',                  '0', true);


      -- 再帰呼び出し
      migrate_kanrikoumoku_buhin_sub(buhin_rec.BUHIN_BANGO, depth_limit - 1);
    end loop;
    
  end migrate_kanrikoumoku_buhin_sub;

  --------------------------------------------------------------
  -- 管理項目マスタ更新(部品)
  --------------------------------------------------------------
  procedure migrate_kanrikoumoku_buhin as 
    cursor cur_buhin is select * from PLMIG_V_C2_KANRI_BUHIN_PARENT ; 
  begin
    start_log('migrate_kanrikoumoku_buhin');
    -- 固定的項目値をセット
    set_kanri_items_buhin;

    -- インデックスを一時的に無効化
    execute IMMEDIATE 'alter index TXBBM001_I02 UNUSABLE';

    g_bulk_ix := 0;
    g_kanri_rec.delete;
    
    for buhin_rec in cur_buhin loop
      -- キー項目をセット
      set_kanri_keys_buhin(buhin_rec);
      
      if (buhin_rec.KOUTEI_BANGO <> '0') then
        migrate_kanrikoumoku_buhin_sub(buhin_rec.KOUTEI_BANGO, 5);
      else
        migrate_kanrikoumoku_buhin_sub(buhin_rec.SEIHIN_BANGO, 5);
      end if;
      
    end loop;
    
    -- バルクインサートのバッファの残りを更新
    forall i in g_kanri_rec.FIRST .. g_kanri_rec.LAST save exceptions
      insert into TXBBM001 
      values g_kanri_rec(i);
    commit;
    
    -- インデックスを最有効化
    execute IMMEDIATE 'alter index TXBBM001_I02 REBUILD';
    finish_log;

  exception
    when others then
      rollback;
      handle_error(SQLCODE, SQLERRM);
  end migrate_kanrikoumoku_buhin;


END PLMIG_PKG_C2;
/
