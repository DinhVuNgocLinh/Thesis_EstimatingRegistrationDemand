USE `digit-curriculum`;

DROP TABLE IF EXISTS dashboard_demand_data;
CREATE TABLE dashboard_demand_data (
    id INT AUTO_INCREMENT PRIMARY KEY,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    demand_type VARCHAR(20), 
    course_id VARCHAR(255),
    course_name VARCHAR(255),
    batch INT,            
    student_count INT, 
    target_year INT,
    target_sem INT,
    INDEX (demand_type),
    INDEX (course_id),
    INDEX (batch),   
    INDEX (target_year, target_sem)
);

DROP PROCEDURE IF EXISTS Refresh_Demand_Dashboard;
DELIMITER //

CREATE PROCEDURE Refresh_Demand_Dashboard(IN p_Year INT, IN p_Sem INT, IN p_MaxCredits INT)
BEGIN
    -- Xóa dữ liệu cũ của kỳ hiện tại
    DELETE FROM dashboard_demand_data WHERE target_year = p_Year AND target_sem = p_Sem;

    -- =============================================
    -- 1. INSERT RETAKE (Học lại)
    -- =============================================
    INSERT INTO dashboard_demand_data (demand_type, course_id, course_name, batch, student_count, target_year, target_sem)
    SELECT 
        'RETAKE', c.id, c.name, s.batch, COUNT(DISTINCT s.id), p_Year, p_Sem
    FROM result r
    JOIN student s ON r.student_id = s.id
    JOIN class_session cs ON r.class_id = cs.id
    JOIN course c ON cs.course_id = c.id
    WHERE r.avg < 50 
      AND s.id NOT IN (
          SELECT r2.student_id FROM result r2 
          JOIN class_session cs2 ON r2.class_id = cs2.id 
          WHERE cs2.course_id = cs.course_id AND r2.avg >= 50
      )
    GROUP BY c.id, c.name, s.batch; -- Gom nhóm theo Khóa

    -- =============================================
    -- 2. INSERT STANDARD (Đúng tiến độ)
    -- =============================================
    INSERT INTO dashboard_demand_data (demand_type, course_id, course_name, batch, student_count, target_year, target_sem)
    SELECT 
        'STANDARD', c.id, c.name, s.batch, COUNT(DISTINCT s.id), p_Year, p_Sem
    FROM student s
    JOIN enrollment_batch eb ON s.enrollment_batch_id = eb.id
    JOIN course_pathway cp ON eb.program_id = cp.program_id AND eb.pathway_id = cp.pathway_id
    JOIN course c ON cp.course_id = c.id
    WHERE cp.`year` = FLOOR( ( ((p_Year - (2000 + s.batch)) * 2 + p_Sem) + 1 ) / 2 )
      AND cp.`semester` = p_Sem
      AND (p_Year - (2000 + s.batch)) BETWEEN 0 AND 6
      AND NOT EXISTS (SELECT 1 FROM result r JOIN class_session cs ON r.class_id = cs.id WHERE r.student_id = s.id AND cs.course_id = c.id AND r.avg >= 50)
    GROUP BY c.id, c.name, s.batch;

    -- =============================================
    -- 3. INSERT LATE (Học trễ)
    -- =============================================
    INSERT INTO dashboard_demand_data (demand_type, course_id, course_name, batch, student_count, target_year, target_sem)
    WITH Student_Backlog AS (
        SELECT s.id AS Student_ID, s.batch AS batch_num, c.id AS C_ID, c.name AS C_Name,
            (c.credit_theory + c.credit_lab) AS C_Credit,
            (cp.`year` - 1) * 2 + cp.`semester` AS C_Idx,
            (p_Year - (2000 + s.batch)) * 2 + p_Sem AS S_Curr_Idx
        FROM student s
        JOIN enrollment_batch eb ON s.enrollment_batch_id = eb.id
        JOIN course_pathway cp ON eb.program_id = cp.program_id AND eb.pathway_id = cp.pathway_id
        JOIN course c ON cp.course_id = c.id
        WHERE (p_Year - (2000 + s.batch)) BETWEEN 0 AND 9
            AND ((cp.`year` - 1) * 2 + cp.`semester`) <= ((p_Year - (2000 + s.batch)) * 2 + p_Sem)
            AND NOT EXISTS (SELECT 1 FROM result r JOIN class_session cs ON r.class_id = cs.id WHERE r.student_id = s.id AND cs.course_id = c.id)
            AND NOT EXISTS (SELECT 1 FROM course_course_relationship rel WHERE rel.course_id1 = c.id AND rel.relationship_id = 1 AND NOT EXISTS (SELECT 1 FROM result r_pre JOIN class_session cs_pre ON r_pre.class_id = cs_pre.id WHERE r_pre.student_id = s.id AND cs_pre.course_id = rel.course_id2 AND r_pre.avg >= 50))
    ),
    Sim_Late AS (
        SELECT *, SUM(C_Credit) OVER (PARTITION BY Student_ID ORDER BY C_Idx ASC, C_ID ASC) AS Acc_Credits FROM Student_Backlog
    )
    SELECT 
        'LATE', C_ID, C_Name, batch_num, COUNT(DISTINCT Student_ID), p_Year, p_Sem 
    FROM Sim_Late WHERE Acc_Credits <= p_MaxCredits AND C_Idx < S_Curr_Idx
    GROUP BY C_ID, C_Name, batch_num;

    -- =============================================
    -- 4. INSERT FAST (Học vượt)
    -- =============================================
    INSERT INTO dashboard_demand_data (demand_type, course_id, course_name, batch, student_count, target_year, target_sem)
    WITH Student_Backlog_Fast AS (
        SELECT s.id AS Student_ID, s.batch AS batch_num, c.id AS C_ID, c.name AS C_Name,
            (c.credit_theory + c.credit_lab) AS C_Credit,
            (cp.`year` - 1) * 2 + cp.`semester` AS C_Idx,
            (p_Year - (2000 + s.batch)) * 2 + p_Sem AS S_Target_Idx
        FROM student s
        JOIN enrollment_batch eb ON s.enrollment_batch_id = eb.id
        JOIN course_pathway cp ON eb.program_id = cp.program_id AND eb.pathway_id = cp.pathway_id
        JOIN course c ON cp.course_id = c.id
        WHERE (p_Year - (2000 + s.batch)) BETWEEN 0 AND 6
            AND ((cp.`year` - 1) * 2 + cp.`semester`) >= ((p_Year - (2000 + s.batch)) * 2 + p_Sem)
            AND ((cp.`year` - 1) * 2 + cp.`semester`) <= ((p_Year - (2000 + s.batch)) * 2 + p_Sem) + 2
            AND NOT EXISTS (SELECT 1 FROM result r JOIN class_session cs ON r.class_id = cs.id WHERE r.student_id = s.id AND cs.course_id = c.id)
            AND NOT EXISTS (SELECT 1 FROM course_course_relationship rel WHERE rel.course_id1 = c.id AND rel.relationship_id = 1 AND NOT EXISTS (SELECT 1 FROM result r_pre JOIN class_session cs_pre ON r_pre.class_id = cs_pre.id WHERE r_pre.student_id = s.id AND cs_pre.course_id = rel.course_id2 AND r_pre.avg >= 50))
    ),
    Sim_Fast AS (
        SELECT *, CASE WHEN C_Idx = S_Target_Idx THEN 'ST' ELSE 'FAST' END AS D_Grp,
            SUM(C_Credit) OVER (PARTITION BY Student_ID ORDER BY C_Idx ASC, C_ID ASC) AS Acc_Credits FROM Student_Backlog_Fast
    )
    SELECT 
        'FAST', C_ID, C_Name, batch_num, COUNT(DISTINCT Student_ID), p_Year, p_Sem 
    FROM Sim_Fast WHERE Acc_Credits <= p_MaxCredits AND D_Grp = 'FAST'
    GROUP BY C_ID, C_Name, batch_num;

END //
DELIMITER ;

-- Gọi chạy Procedure
CALL Refresh_Demand_Dashboard(2025, 2, 24);

-- Kiểm tra kết quả dạng dọc
SELECT * FROM dashboard_demand_data ORDER BY course_name, batch;